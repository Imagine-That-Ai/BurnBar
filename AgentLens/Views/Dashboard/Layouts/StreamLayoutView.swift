import OpenBurnBarKernel
import OpenBurnBarUI
import SwiftUI

// MARK: - Stream (storage id `stream`)
//
// For the temporal thinker — the person whose first question is always "when did
// that happen?" and who reconstructs a bill by remembering the week.
//
// Thesis: time is the primary axis and everything hangs off it. A single
// chronological river runs down the page: newest day first, a spine rule down the
// left gutter, each day's total on the spine and its sessions branching off it.
// Days that ran hot get called out where they happened rather than in a separate
// "alerts" box, because an alert detached from its moment is trivia.
//
// Primary axis: time, descending. Dominant element: the spine.
// Density: medium — dense inside a day, generous between days.
//
// Enforced rule: **every row is anchored to a timestamp.** Nothing in this file
// aggregates across the whole window except the spine header, and nothing is
// ranked. If a section here ever sorts by cost, that is Atlas.

extension DashboardView {
    var streamLayout: some View {
        conceptCanvas(maxWidth: 900, spacing: DesignSystem.Spacing.lg) {
            conceptUpdateBanner
            streamHeader
            if streamDays.isEmpty {
                streamEmptyState
            } else {
                ForEach(streamDays) { day in
                    streamDaySection(day)
                }
            }
            conceptDetailsDrawer(includesLiveCurve: false)
        }
    }

    // MARK: Header

    private var streamHeader: some View {
        DashboardSection(
            "Timeline",
            title: selectedTimeRange.displayName,
            accent: DesignSystem.Colors.amber,
            density: .compact,
            accessory: {
                Text("NEWEST FIRST")
                    .font(DesignSystem.Typography.tiny)
                    .tracking(1.2)
                    .foregroundStyle(dashboardSectionInk.subtle)
            },
            content: {
                VStack(spacing: 0) {
                    DashboardSectionMetric(
                        label: "Days with activity",
                        value: streamDays.count.formatted(),
                        accent: DesignSystem.Colors.amber
                    )
                    .padding(.vertical, 7)
                    DashboardSectionRule()
                    DashboardSectionMetric(
                        label: "Busiest day",
                        value: streamBusiestDay?.total.formatAsCost() ?? "—",
                        accent: DesignSystem.Colors.whimsy,
                        caption: streamBusiestDay.map { streamDayLabel($0.date) }
                    )
                    .padding(.vertical, 7)
                    DashboardSectionRule()
                    DashboardSectionMetric(
                        label: "Daily mean in window",
                        value: streamDailyMean.formatAsCost(),
                        accent: DesignSystem.Colors.ember
                    )
                    .padding(.vertical, 7)
                }
            }
        )
    }

    private var streamEmptyState: some View {
        DashboardSection("Timeline", density: .compact, emphasis: .quiet) {
            Text("Nothing landed in this window. Sessions appear here the moment they are mined.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(dashboardSectionInk.subtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: One day on the river

    private func streamDaySection(_ day: StreamDay) -> some View {
        DashboardSection(
            streamDayLabel(day.date),
            accent: day.isSpike ? DesignSystem.Colors.warning : DesignSystem.Colors.amber,
            density: .compact,
            emphasis: day.isSpike ? .featured : .standard,
            accessory: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    if day.isSpike {
                        Label(
                            String(format: "%.1f× mean", day.total / max(streamDailyMean, 0.0001)),
                            systemImage: "flame.fill"
                        )
                        .labelStyle(.titleAndIcon)
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.warning)
                    }
                    Text(day.total.formatAsCost())
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(dashboardSectionInk.primary)
                }
            },
            content: {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                    // The spine. It is the layout's whole thesis rendered as one
                    // rectangle: everything to its right happened at a time.
                    Capsule()
                        .fill(
                            day.isSpike
                                ? DesignSystem.Colors.warning.opacity(0.6)
                                : dashboardSectionInk.hairline
                        )
                        .frame(width: 2)
                        .accessibilityHidden(true)

                    VStack(spacing: 0) {
                        ForEach(Array(day.entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { DashboardSectionRule() }
                            streamEntryRow(entry)
                        }
                        if day.hiddenCount > 0 {
                            DashboardSectionRule()
                            Text("+\(day.hiddenCount.formatted()) more session\(day.hiddenCount == 1 ? "" : "s") this day")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(dashboardSectionInk.subtle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 7)
                        }
                    }
                }
            }
        )
    }

    private func streamEntryRow(_ entry: StreamEntry) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Text(entry.time)
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(dashboardSectionInk.subtle)
                .frame(width: 58, alignment: .leading)
            ProviderLogoView(provider: entry.provider, size: 18, useFallbackColor: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(dashboardSectionInk.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(dashboardSectionInk.subtle)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignSystem.Spacing.sm)
            Text(entry.cost.formatAsCost())
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(dashboardSectionInk.primary)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.time), \(entry.title), \(entry.cost.formatAsCost())")
    }

    // MARK: Model

    /// Sessions that ran on one calendar day, newest first.
    struct StreamDay: Identifiable {
        let date: Date
        let total: Double
        let entries: [StreamEntry]
        /// Sessions past the per-day render cap, summarised rather than dropped.
        let hiddenCount: Int
        /// Ran hot against the window's own daily mean.
        let isSpike: Bool

        var id: Date { date }
    }

    struct StreamEntry: Identifiable {
        let id: String
        let time: String
        let provider: AgentProvider
        let title: String
        let detail: String
        let cost: Double
    }

    /// Cap on rows rendered per day.
    ///
    /// A single heavy day can hold thousands of usage rows, and a river you
    /// cannot scroll out of is not a river. The remainder is counted, not
    /// discarded, so the day total on the spine always reconciles.
    private var streamRowsPerDay: Int { 12 }
    /// Cap on days rendered, for the same reason. "All Time" is a valid window.
    private var streamMaxDays: Int { 30 }

    /// The window's usage rows grouped into calendar days.
    private var usagesByDay: [Date: [TokenUsage]] {
        let calendar = Calendar.current
        return Dictionary(grouping: dashboardUsageWindow.usages) { usage in
            calendar.startOfDay(for: min(usage.startTime, usage.endTime))
        }
    }

    /// Groups the window's usage into calendar days, newest first.
    var streamDays: [StreamDay] {
        let grouped = usagesByDay
        let mean = streamDailyMean
        return grouped
            .sorted { $0.key > $1.key }
            .prefix(streamMaxDays)
            .map { date, rows in
                let total = rows.reduce(0) { $0 + max(0, $1.cost) }
                let ordered = rows.sorted {
                    max($0.startTime, $0.endTime) > max($1.startTime, $1.endTime)
                }
                let entries = ordered.prefix(streamRowsPerDay).map { usage in
                    StreamEntry(
                        id: usage.id.uuidString,
                        time: max(usage.startTime, usage.endTime)
                            .formatted(date: .omitted, time: .shortened),
                        provider: usage.provider,
                        title: usage.model.isEmpty ? usage.provider.displayName : usage.model,
                        detail: streamEntryDetail(usage),
                        cost: usage.cost
                    )
                }
                return StreamDay(
                    date: date,
                    total: total,
                    entries: Array(entries),
                    hiddenCount: max(0, ordered.count - streamRowsPerDay),
                    // 1.5× the window's own mean, not an absolute dollar figure:
                    // "hot" has to mean hot *for this user*.
                    isSpike: mean > 0 && total >= mean * 1.5
                )
            }
    }

    private func streamEntryDetail(_ usage: TokenUsage) -> String {
        let project = usage.projectName.isEmpty ? usage.provider.displayName : usage.projectName
        return "\(project) · \(usage.totalTokens.formatted()) tokens"
    }

    private var streamBusiestDay: StreamDay? {
        streamDays.max { $0.total < $1.total }
    }

    /// Mean spend across the days that actually had activity.
    ///
    /// Deliberately not "window total ÷ calendar days": a user who works three
    /// days a week should not have their busy days flagged as spikes because the
    /// weekend dragged the mean down.
    private var streamDailyMean: Double {
        let byDay = usagesByDay
        guard !byDay.isEmpty else { return 0 }
        let total = dashboardUsageWindow.usages.reduce(0) { $0 + max(0, $1.cost) }
        return total / Double(byDay.count)
    }

    private func streamDayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
