import AppKit
import CodexBarCore
import SwiftUI

extension StatusItemController {
    var fallbackProvider: UsageProvider? {
        // Intentionally uses availability-filtered list: fallback activates when no provider
        // can actually work, ensuring at least a codex icon is always visible.
        self.store.enabledProviders().isEmpty ? .codex : nil
    }
}

extension ProviderSwitcherSelection {
    var provider: UsageProvider? {
        switch self {
        case .overview:
            nil
        case let .provider(provider):
            provider
        }
    }
}

struct OverviewMenuCardRowView: View {
    let model: UsageMenuCardView.Model
    let storageText: String?
    let width: CGFloat
    @Environment(\.menuItemHighlighted) private var isHighlighted
    @Environment(\.menuCardRefreshMonitor) private var refreshMonitor

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            self.providerIconView

            VStack(alignment: .leading, spacing: 4) {
                self.headerLine
                self.metricsLine
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: self.width, alignment: .leading)
    }

    private var providerIconView: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.15))
                .frame(width: 26, height: 26)

            if let brand = ProviderBrandIcon.image(for: self.model.provider) {
                Image(nsImage: brand)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(UsageMenuCardView.progressColor(for: self.model.provider))
            } else {
                Image(systemName: "circle.dotted")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(UsageMenuCardView.progressColor(for: self.model.provider))
            }
        }
        .accessibilityHidden(true)
    }

    private var headerLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(self.model.providerName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                .lineLimit(1)
                .layoutPriority(1)

            if let subtitle = self.headerSubtitleText {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(self.headerSubtitleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    static func overviewMetrics(for model: UsageMenuCardView.Model) -> [UsageMenuCardView.Model.Metric] {
        model.metrics.filter { metric in
            if model.provider == .claude {
                if metric.id == "claude-routines" || metric.title.localizedCaseInsensitiveContains("routine") {
                    return false
                }
            }
            return true
        }
    }

    private var overviewMetrics: [UsageMenuCardView.Model.Metric] {
        Self.overviewMetrics(for: self.model)
    }

    private var metricsLine: some View {
        Group {
            if !self.overviewMetrics.isEmpty {
                HStack(spacing: 12) {
                    ForEach(self.overviewMetrics.prefix(4), id: \.id) { metric in
                        CompactMetricItemView(metric: metric, isHighlighted: self.isHighlighted)
                    }
                }
            } else if let placeholder = self.model.placeholder {
                Text(placeholder)
                    .font(.system(size: 11))
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            } else if self.model.subtitleStyle == .error {
                Text(self.model.subtitleText)
                    .font(.system(size: 11))
                    .foregroundStyle(MenuHighlightStyle.error(self.isHighlighted))
                    .lineLimit(1)
            }
        }
    }

    private var liveSubtitle: MenuCardLiveSubtitle {
        let fallback = MenuCardLiveSubtitle(text: self.model.subtitleText, style: self.model.subtitleStyle)
        guard self.model.usesLiveSubtitle else { return fallback }
        return self.refreshMonitor?.subtitle(for: self.model.provider, fallback: fallback) ?? fallback
    }

    private var headerSubtitleColor: Color {
        let live = self.liveSubtitle
        if live.style == .error {
            return MenuHighlightStyle.error(self.isHighlighted)
        }
        return MenuHighlightStyle.secondary(self.isHighlighted)
    }

    private var primaryResetText: String? {
        if let reset = self.overviewMetrics.first(where: {
            guard let text = $0.resetText?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !text.isEmpty
        })?.resetText {
            return reset
        }
        let live = self.liveSubtitle
        if live.style == .info, !live.text.isEmpty, live.text != L("Not fetched yet") {
            return live.text
        }
        return nil
    }

    private var headerSubtitleText: String? {
        let live = self.liveSubtitle
        if live.style == .error {
            return live.text
        }
        if live.style == .loading {
            return live.text
        }
        if let reset = self.primaryResetText {
            return reset
        }
        if !live.text.isEmpty, live.text != L("Not fetched yet") {
            return live.text
        }
        return nil
    }

    static func compactMetricLabel(title: String, id: String) -> String {
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if lower.contains("5-hour") || lower.contains("5 hour") || lower.contains("5h") || lower.contains("session") {
            return "5h"
        }
        if lower.contains("2-hour") || lower.contains("2 hour") || lower.contains("2h") {
            return "2h"
        }
        if lower.contains("hourly") || lower.contains("1-hour") || lower.contains("1 hour") || lower.contains("1h") {
            return "1h"
        }
        if lower.contains("weekly") || lower.contains("week") || lower.contains("7-day") || lower.contains("7d") ||
            lower == "wk"
        {
            return "wk"
        }
        if lower.contains("monthly") || lower.contains("month") || lower.contains("30-day") || lower.contains("30d") {
            return "30d"
        }
        if lower.contains("code review") {
            return "Review"
        }
        if lower.contains("requests") || lower.contains("request") {
            return "req"
        }
        if lower.contains("balance") {
            return "bal"
        }
        if lower.contains("credits") || lower.contains("credit") {
            return "cr"
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 7 {
            return trimmed
        }
        if let firstWord = trimmed.split(separator: " ").first, firstWord.count <= 7 {
            return String(firstWord)
        }
        return String(trimmed.prefix(6))
    }
}

private struct CompactMetricItemView: View {
    let metric: UsageMenuCardView.Model.Metric
    let isHighlighted: Bool

    private var isWarning: Bool {
        switch self.metric.percentStyle {
        case .used:
            self.metric.percent >= 80.0
        case .left:
            self.metric.percent <= 20.0 && self.metric.percent >= 0
        }
    }

    private var label: String {
        OverviewMenuCardRowView.compactMetricLabel(title: self.metric.title, id: self.metric.id)
    }

    private var percentText: String {
        "\(Int(max(0, min(100, round(self.metric.percent)))))%"
    }

    private var barFillColor: Color {
        if self.isWarning {
            return MenuHighlightStyle.error(self.isHighlighted)
        }
        return MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.7)
    }

    private var textColor: Color {
        if self.isWarning {
            return MenuHighlightStyle.error(self.isHighlighted)
        }
        if self.metric.percent <= 0 {
            return MenuHighlightStyle.secondary(self.isHighlighted)
        }
        return MenuHighlightStyle.primary(self.isHighlighted)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(self.label)
                .font(.system(size: 11))
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                .lineLimit(1)

            if let status = self.metric.statusText, !status.isEmpty, self.metric.percent == 0 {
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(self.textColor)
                    .lineLimit(1)
            } else {
                GeometryReader { geometry in
                    let totalWidth = geometry.size.width
                    let fillRatio = max(0, min(1.0, self.metric.percent / 100.0))
                    let fillWidth = totalWidth * fillRatio

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(MenuHighlightStyle.progressTrack(self.isHighlighted))

                        Capsule()
                            .fill(self.barFillColor)
                            .frame(width: fillWidth)
                    }
                }
                .frame(width: 32, height: 4)

                Text(self.percentText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(self.textColor)
                    .lineLimit(1)
            }
        }
    }
}

struct OpenAIWebMenuItems {
    let hasUsageBreakdown: Bool
    let hasCreditsHistory: Bool
    let hasCostHistory: Bool
    let canShowBuyCredits: Bool
}

struct TokenAccountMenuDisplay: Equatable {
    let provider: UsageProvider
    let accounts: [ProviderTokenAccount]
    let snapshots: [TokenAccountUsageSnapshot]
    let activeIndex: Int
    let layout: MultiAccountMenuLayout

    var showAll: Bool {
        self.layout == .stacked
    }

    var showSwitcher: Bool {
        self.layout == .segmented
    }

    static func == (lhs: TokenAccountMenuDisplay, rhs: TokenAccountMenuDisplay) -> Bool {
        lhs.provider == rhs.provider &&
            lhs.accountIdentity == rhs.accountIdentity &&
            lhs.activeIndex == rhs.activeIndex &&
            lhs.layout == rhs.layout &&
            lhs.snapshotIdentity == rhs.snapshotIdentity
    }

    private var accountIdentity: [AccountIdentity] {
        self.accounts.map { account in
            AccountIdentity(
                id: account.id,
                label: account.label,
                externalIdentifier: account.externalIdentifier,
                usageScope: account.usageScope,
                organizationID: account.organizationID,
                workspaceID: account.workspaceID)
        }
    }

    private var snapshotIdentity: [SnapshotIdentity] {
        self.snapshots.map { snapshot in
            SnapshotIdentity(
                id: snapshot.id,
                hasSnapshot: snapshot.snapshot != nil,
                error: snapshot.error,
                sourceLabel: snapshot.sourceLabel)
        }
    }

    private struct AccountIdentity: Equatable {
        let id: UUID
        let label: String
        let externalIdentifier: String?
        let usageScope: String?
        let organizationID: String?
        let workspaceID: String?
    }

    private struct SnapshotIdentity: Equatable {
        let id: UUID
        let hasSnapshot: Bool
        let error: String?
        let sourceLabel: String?
    }
}

struct CodexAccountMenuDisplay: Equatable {
    let accounts: [CodexVisibleAccount]
    let snapshots: [CodexAccountUsageSnapshot]
    let activeVisibleAccountID: String?
    let layout: MultiAccountMenuLayout

    var showAll: Bool {
        self.layout == .stacked
    }

    var showSwitcher: Bool {
        self.layout == .segmented
    }

    var workspaceSections: [CodexAccountWorkspaceSection] {
        self.accounts.codexWorkspaceSections()
    }

    var showsWorkspaceGroups: Bool {
        Set(self.workspaceSections.map(\.title)).count > 1
    }

    static func == (lhs: CodexAccountMenuDisplay, rhs: CodexAccountMenuDisplay) -> Bool {
        lhs.accounts == rhs.accounts &&
            lhs.activeVisibleAccountID == rhs.activeVisibleAccountID &&
            lhs.layout == rhs.layout &&
            lhs.snapshotIdentity == rhs.snapshotIdentity
    }

    private var snapshotIdentity: [SnapshotIdentity] {
        self.snapshots.map { snapshot in
            SnapshotIdentity(
                id: snapshot.id,
                hasSnapshot: snapshot.snapshot != nil,
                error: snapshot.error,
                sourceLabel: snapshot.sourceLabel)
        }
    }

    private struct SnapshotIdentity: Equatable {
        let id: String
        let hasSnapshot: Bool
        let error: String?
        let sourceLabel: String?
    }
}
