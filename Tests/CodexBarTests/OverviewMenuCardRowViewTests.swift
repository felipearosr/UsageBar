import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct OverviewMenuCardRowViewTests {
    @Test
    func `compactMetricLabel maps common time windows correctly`() {
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "5-hour", id: "primary") == "5h")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "5-Hour", id: "primary") == "5h")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "5h Session", id: "primary") == "5h")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "5h limit", id: "primary") == "5h")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Session", id: "primary") == "5h")

        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "2-Hour", id: "primary") == "2h")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Hourly", id: "primary") == "1h")

        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Weekly", id: "secondary") == "wk")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Week", id: "secondary") == "wk")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "7-day", id: "secondary") == "wk")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "7d", id: "secondary") == "wk")

        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Monthly", id: "tertiary") == "30d")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Month", id: "tertiary") == "30d")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "30-day", id: "tertiary") == "30d")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "30d", id: "tertiary") == "30d")
    }

    @Test
    func `compactMetricLabel maps standard special metric names and preserves short names`() {
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Code review", id: "review") == "Review")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Requests", id: "requests") == "req")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Balance", id: "balance") == "bal")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Credits", id: "credits") == "cr")

        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Fable", id: "fable") == "Fable")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Sonnet", id: "sonnet") == "Sonnet")
        #expect(OverviewMenuCardRowView.compactMetricLabel(title: "Opus", id: "opus") == "Opus")
    }

    @Test
    func `overview row initializes with model and storageText`() throws {
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: nil,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: AccountInfo(email: "test@example.com", plan: "Pro"),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: Date(timeIntervalSince1970: 0)))

        let view = OverviewMenuCardRowView(model: model, storageText: "2.4 GB", width: 320)
        #expect(view.storageText == "2.4 GB")
        #expect(view.width == 320)
        #expect(view.model.provider == .claude)
    }

    @Test
    func `overviewMetrics filters out daily routines for claude`() throws {
        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7200),
                resetDescription: nil),
            tertiary: RateWindow(
                usedPercent: 30,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(7800),
                resetDescription: nil),
            extraRateWindows: [
                NamedRateWindow(
                    id: "claude-routines",
                    title: "Daily Routines",
                    window: RateWindow(
                        usedPercent: 5,
                        windowMinutes: 10080,
                        resetsAt: now.addingTimeInterval(8200),
                        resetDescription: nil)),
            ],
            updatedAt: now)
        let metadata = try #require(ProviderDefaults.metadata[.claude])
        let model = UsageMenuCardView.Model.make(.init(
            provider: .claude,
            metadata: metadata,
            snapshot: snapshot,
            credits: nil,
            creditsError: nil,
            dashboard: nil,
            dashboardError: nil,
            tokenSnapshot: nil,
            tokenError: nil,
            account: nil,
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: true,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: false,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            now: now))

        let overviewMetrics = OverviewMenuCardRowView.overviewMetrics(for: model)
        #expect(overviewMetrics.map(\.title) == ["Session", "Weekly", "Sonnet"])
        #expect(!overviewMetrics.contains(where: { $0.id == "claude-routines" }))
    }
}
