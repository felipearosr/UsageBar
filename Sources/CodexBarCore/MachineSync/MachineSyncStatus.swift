import Foundation

// MARK: - Reporting Day

/// The timezone and day boundary used to group Spend Buckets into days for display (§8.3).
///
/// Spend Buckets are whole UTC hours, so in a timezone with a fractional offset a bucket counts toward the day
/// its first minute falls in.
public struct MachineSyncReportingDay: Codable, Sendable, Equatable {
    /// IANA identifier; `nil` means the system timezone.
    public var timeZone: String?
    /// Local hour (0–23) at which a Reporting Day starts.
    public var startHour: Int

    public init(timeZone: String? = nil, startHour: Int = 0) {
        self.timeZone = timeZone
        self.startHour = startHour
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
        self.startHour = try container.decodeIfPresent(Int.self, forKey: .startHour) ?? 0
    }

    public var isValid: Bool {
        (0...23).contains(self.startHour) && self.timeZone.map { TimeZone(identifier: $0) != nil } ?? true
    }

    public var resolvedTimeZone: TimeZone {
        self.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = self.resolvedTimeZone
        return calendar
    }

    /// The Reporting Day (`YYYY-MM-DD`) that `instant` belongs to.
    public func day(of instant: Date) -> String {
        let calendar = self.calendar
        let local = calendar.dateComponents([.year, .month, .day, .hour], from: instant)
        var date = DateComponents(year: local.year, month: local.month, day: local.day)
        if (local.hour ?? 0) < self.startHour {
            let noon = calendar.date(from: DateComponents(
                year: local.year, month: local.month, day: local.day, hour: 12))!
            let previous = calendar.date(byAdding: .day, value: -1, to: noon)!
            date = calendar.dateComponents([.year, .month, .day], from: previous)
        }
        return MachineSyncDay.dateString(date)
    }

    /// `count` consecutive Reporting Days ending with the one that contains `now`, oldest first.
    public func days(endingAt now: Date, count: Int) -> [String] {
        let calendar = self.calendar
        let today = self.day(of: now)
        let parts = today.split(separator: "-").compactMap { Int($0) }
        let noon = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
        return (0..<count).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: noon)!
            return MachineSyncDay.dateString(calendar.dateComponents([.year, .month, .day], from: date))
        }
    }
}

// MARK: - Cache

/// Decrypted copy of a Sync Group's blobs plus the `changes` cursor, so each read fetches only new blobs.
public struct MachineSyncCache: Codable, Sendable, Equatable {
    public struct Machine: Codable, Sendable, Equatable {
        public var lastSeen: Date?
        public var profile: MachineSyncProfile?
        /// Keyed by UTC date (`YYYY-MM-DD`).
        public var days: [String: MachineSyncDayBlob] = [:]
    }

    public struct BlobError: Codable, Sendable, Equatable {
        public var machineID: String
        public var name: String
        public var reason: String

        enum CodingKeys: String, CodingKey {
            case machineID = "machineId"
            case name
            case reason
        }
    }

    public var version: Int = 1
    public var groupID: String
    public var cursor: String?
    public var retentionDays: Int?
    public var machines: [String: Machine] = [:]
    /// Retired Machines and when they were retired (group blob `retired`, §5.3).
    public var retired: [String: Date] = [:]
    /// Blobs that couldn't be read, keyed by `machine-id/name`. Cleared when a later copy reads fine.
    public var errors: [String: BlobError] = [:]

    public init(groupID: String) {
        self.groupID = groupID
    }
}

// MARK: - Reader

public struct MachineSyncRefreshResult: Sendable {
    public let cache: MachineSyncCache
    /// Blobs received from the server by this refresh.
    public let fetchedBlobs: Int
}

public enum MachineSyncReader {
    static let pageLimit = 500

    /// Pulls every blob written since the cached cursor (§6.5), decrypts it into the local cache, and saves it.
    /// A blob that fails to decrypt or parse is dropped from the cache and recorded in `errors`.
    public static func refresh(environment: MachineSyncEnvironment) async throws -> MachineSyncRefreshResult {
        guard let settings = try environment.store.loadSettings(), let rawLink = settings.pairingLink else {
            throw MachineSyncError.notPaired
        }
        let link = try MachineSyncPairingLink(parsing: rawLink)
        let keys = link.keys
        let client = MachineSyncClient(apiBaseURL: link.apiBaseURL, transport: environment.transport)

        // A missing, unreadable, or other-group cache is rebuilt from scratch.
        var cache = MachineSyncCache(groupID: keys.groupIDBase64URL)
        if let saved = try? environment.store.loadCache(), saved.groupID == keys.groupIDBase64URL {
            cache = saved
        }

        var fetched = 0
        var listed: Set<String> = []
        var lastSeen: [String: Date] = [:]
        repeat {
            let page = try await client.changes(keys: keys, since: cache.cursor, limit: Self.pageLimit)
            if let retentionDays = page.limits?.retentionDays {
                cache.retentionDays = retentionDays
            }
            for machine in page.machines where MachineSyncMachineID.isValid(machine.machineId) {
                listed.insert(machine.machineId)
                lastSeen[machine.machineId] = machine.lastSeen.flatMap(Self.parseDate)
            }
            for blob in page.blobs {
                Self.apply(blob, keys: keys, to: &cache)
            }
            fetched += page.blobs.count
            let advanced = page.cursor != cache.cursor
            cache.cursor = page.cursor
            // A server that says `hasMore` without moving the cursor would otherwise loop forever.
            if !page.hasMore || !advanced { break }
        } while true

        // `machines` always lists the whole group, so anything missing was forgotten on the server (§6.7).
        cache.machines = cache.machines.filter {
            listed.contains($0.key)
        }
        for machineID in listed {
            cache.machines[machineID, default: MachineSyncCache.Machine()].lastSeen = lastSeen[machineID]
        }
        cache.errors = cache.errors.filter {
            $0.value.machineID == MachineSyncMachineID.group || listed.contains($0.value.machineID)
        }
        Self.pruneExpiredDays(&cache, now: environment.now())

        try environment.store.saveCache(cache)
        return MachineSyncRefreshResult(cache: cache, fetchedBlobs: fetched)
    }

    private struct Header: Decodable {
        let v: Int
    }

    private struct RetiredBlob: Decodable {
        struct Entry: Decodable {
            let retiredAt: String
        }

        let machines: [String: Entry]
    }

    static func apply(
        _ blob: MachineSyncClient.ChangesPage.Blob,
        keys: MachineSyncKeys,
        to cache: inout MachineSyncCache)
    {
        let key = "\(blob.machineId)/\(blob.name)"
        let isGroup = blob.machineId == MachineSyncMachineID.group
        let isDay = blob.name.hasPrefix("day-")
        guard isGroup ? blob.name == "retired" : (blob.name == "profile" || isDay) else { return }

        // Whatever happens next, the old copy is superseded and must not be shown.
        if isGroup {
            cache.retired = [:]
        } else if isDay {
            cache.machines[blob.machineId]?.days[String(blob.name.dropFirst("day-".count))] = nil
        } else {
            cache.machines[blob.machineId]?.profile = nil
        }

        func fail(_ reason: String) {
            cache.errors[key] = MachineSyncCache.BlobError(machineID: blob.machineId, name: blob.name, reason: reason)
        }
        guard let envelope = Data(base64Encoded: blob.body) else { return fail("not valid base64") }
        let plaintext: Data
        do {
            plaintext = try MachineSyncEnvelope.open(
                envelope,
                encKey: keys.encKey,
                address: MachineSyncBlobAddress(
                    groupID: keys.groupIDBase64URL,
                    machineID: blob.machineId,
                    name: blob.name))
        } catch {
            return fail("couldn't decrypt")
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: plaintext) else { return fail("not valid JSON") }
        cache.errors[key] = nil
        // Readers skip blob versions they don't understand (§11).
        guard header.v == 1 else { return }

        do {
            if isGroup {
                let retired = try decoder.decode(RetiredBlob.self, from: plaintext)
                cache.retired = retired.machines.compactMapValues { Self.parseDate($0.retiredAt) }
            } else if isDay {
                let day = try decoder.decode(MachineSyncDayBlob.self, from: plaintext)
                cache.machines[blob.machineId, default: MachineSyncCache.Machine()]
                    .days[String(blob.name.dropFirst("day-".count))] = day
            } else {
                let profile = try decoder.decode(MachineSyncProfile.self, from: plaintext)
                cache.machines[blob.machineId, default: MachineSyncCache.Machine()].profile = profile
            }
        } catch {
            fail("not a valid \(isDay ? "day" : blob.name) blob")
        }
    }

    /// The server deletes days past retention without telling readers (§7), so the cache drops them too.
    static func pruneExpiredDays(_ cache: inout MachineSyncCache, now: Date) {
        guard let oldest = MachineSyncDay.oldestRetainedDate(retentionDays: cache.retentionDays, now: now) else {
            return
        }
        cache.machines = cache.machines.mapValues { machine in
            var machine = machine
            machine.days = machine.days.filter { $0.key >= oldest }
            return machine
        }
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

extension MachineSyncDay {
    /// UTC date of the oldest `day-*` blob the server still keeps, or `nil` when retention is unknown.
    static func oldestRetainedDate(retentionDays: Int?, now: Date) -> String? {
        retentionDays.map { self.dateString(for: self.startOfDay(now).addingTimeInterval(-86400 * Double($0))) }
    }
}

// MARK: - Status

/// Every Machine's Spend as `codexbar sync status` shows it. Encodes to the `--json` payload.
public struct MachineSyncStatus: Encodable, Sendable, Equatable {
    public struct Spend: Encodable, Sendable, Equatable {
        public var costUSD: Double = 0
        /// Some buckets had no price, so `costUSD` is a lower bound.
        public var costIncomplete = false
        public var totalTokens = 0
        public var requests = 0

        public var isEmpty: Bool {
            self.costUSD == 0 && !self.costIncomplete && self.totalTokens == 0 && self.requests == 0
        }

        mutating func add(_ bucket: MachineSyncDayBlob.Bucket) {
            if let cost = bucket.costUSD {
                self.costUSD += cost
            } else {
                self.costIncomplete = true
            }
            self.totalTokens += bucket.totalTokens ?? 0
            self.requests += bucket.requests ?? 0
        }

        mutating func add(_ other: Spend) {
            self.costUSD += other.costUSD
            self.costIncomplete = self.costIncomplete || other.costIncomplete
            self.totalTokens += other.totalTokens
            self.requests += other.requests
        }
    }

    public struct ModelSpend: Encodable, Sendable, Equatable {
        public let provider: String
        public let model: String
        public let spend: Spend
    }

    public struct DaySpend: Encodable, Sendable, Equatable {
        /// Reporting Day, `YYYY-MM-DD`.
        public let date: String
        public let spend: Spend
    }

    /// The UTC dates this Machine's synced Spend spans (from `coverageStart` to Last Seen). Never "lifetime".
    public struct Coverage: Encodable, Sendable, Equatable {
        public let from: String
        public let to: String
    }

    public struct Machine: Encodable, Sendable, Equatable {
        public let machineId: String
        public let displayName: String
        public let platform: String?
        public let clientVersion: String?
        public let isThisMachine: Bool
        public let lastSeen: Date?
        public let active: Bool
        public let retired: Bool
        public let today: Spend
        public let last30Days: Spend
        /// Last 30 Reporting Days, split by provider and model, most expensive first.
        public let models: [ModelSpend]
        /// Last 30 Reporting Days that have Spend, oldest first.
        public let days: [DaySpend]
        public let coverage: Coverage?
    }

    public struct ReportingDay: Encodable, Sendable, Equatable {
        public let timeZone: String
        public let startHour: Int
    }

    public struct Totals: Encodable, Sendable, Equatable {
        public let today: Spend
        public let last30Days: Spend
    }

    public let generatedAt: Date
    public let reportingDay: ReportingDay
    /// The Reporting Day that contains `generatedAt`.
    public let today: String
    public let machines: [Machine]
    public let total: Totals
    public let errors: [MachineSyncCache.BlobError]

    /// A Machine is active while its Last Seen is under 5 minutes old (§8.3).
    public static let activeWindow: TimeInterval = 5 * 60
    public static let windowDays = 30

    public init(
        cache: MachineSyncCache,
        thisMachineID: String?,
        reportingDay: MachineSyncReportingDay,
        now: Date)
    {
        let window = reportingDay.days(endingAt: now, count: Self.windowDays)
        let windowSet = Set(window)
        let today = window.last ?? reportingDay.day(of: now)
        let oldestRetained = MachineSyncDay.oldestRetainedDate(retentionDays: cache.retentionDays, now: now)

        var machines: [Machine] = []
        var totalToday = Spend()
        var total30 = Spend()
        for (machineID, cached) in cache.machines {
            var byDay: [String: Spend] = [:]
            var byModel: [String: (provider: String, model: String, spend: Spend)] = [:]
            for (utcDate, blob) in cached.days {
                for bucket in blob.buckets {
                    guard let hourStart = MachineSyncDay.hourStart(utcDate: utcDate, hour: bucket.hour)
                    else { continue }
                    let day = reportingDay.day(of: hourStart)
                    guard windowSet.contains(day) else { continue }
                    byDay[day, default: Spend()].add(bucket)
                    let key = "\(bucket.provider)/\(bucket.model)"
                    byModel[key, default: (bucket.provider, bucket.model, Spend())].spend.add(bucket)
                }
            }
            var last30 = Spend()
            byDay.values.forEach { last30.add($0) }
            let todaySpend = byDay[today] ?? Spend()

            let retiredAt = cache.retired[machineID]
            // A retired Machine that pushes again counts as active again (§5.3).
            let retired = retiredAt.map { retiredAt in cached.lastSeen.map { $0 <= retiredAt } ?? true } ?? false
            let active = !retired && cached.lastSeen.map { now.timeIntervalSince($0) < Self.activeWindow } ?? false

            machines.append(Machine(
                machineId: machineID,
                displayName: cached.profile?.displayName ?? machineID,
                platform: cached.profile?.platform,
                clientVersion: cached.profile?.clientVersion,
                isThisMachine: machineID == thisMachineID,
                lastSeen: cached.lastSeen,
                active: active,
                retired: retired,
                today: todaySpend,
                last30Days: last30,
                models: byModel.values
                    .map { ModelSpend(provider: $0.provider, model: $0.model, spend: $0.spend) }
                    .sorted { ($0.spend.costUSD, $1.provider, $1.model) > ($1.spend.costUSD, $0.provider, $0.model) },
                days: window.compactMap { day in byDay[day].map { DaySpend(date: day, spend: $0) } },
                coverage: Self.coverage(cached, oldestRetained: oldestRetained)))
            totalToday.add(todaySpend)
            total30.add(last30)
        }

        self.generatedAt = now
        self.reportingDay = ReportingDay(
            // As configured: Foundation may report an alias (Linux turns "UTC" into "GMT").
            timeZone: reportingDay.timeZone ?? reportingDay.resolvedTimeZone.identifier,
            startHour: reportingDay.startHour)
        self.today = today
        self.machines = machines.sorted {
            ($0.isThisMachine ? 0 : 1, $0.displayName.lowercased(), $0.machineId)
                < ($1.isThisMachine ? 0 : 1, $1.displayName.lowercased(), $1.machineId)
        }
        self.total = Totals(today: totalToday, last30Days: total30)
        self.errors = cache.errors.values.sorted { ($0.machineID, $0.name) < ($1.machineID, $1.name) }
    }

    private static func coverage(_ machine: MachineSyncCache.Machine, oldestRetained: String?) -> Coverage? {
        guard var from = machine.profile?.coverageStart ?? machine.days.keys.min() else { return nil }
        if let oldestRetained {
            from = max(from, oldestRetained)
        }
        guard let to = machine.lastSeen.map(MachineSyncDay.dateString(for:)) ?? machine.days.keys.max(),
              from <= to
        else { return nil }
        return Coverage(from: from, to: to)
    }
}

extension MachineSyncDay {
    /// Start of `hour` (UTC) on `utcDate` (`YYYY-MM-DD`).
    static func hourStart(utcDate: String, hour: Int) -> Date? {
        let parts = utcDate.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (0...23).contains(hour) else { return nil }
        return self.utcCalendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: hour))
    }
}
