import SwiftUI

// MARK: - QuotaResetAtlas
//
// 7-day-forward horizontal calendar of next-reset events. Each day is a
// vertical column with a header label; reset markers stack vertically inside
// the column they fall into so multiple plans that reset on the same day
// remain readable instead of collapsing to a single overlap point.

struct QuotaResetAtlas: View {

    let entries: [SubscriptionEntry]

    private static let daysForward = 7

    // MARK: Day bucketing

    private struct DayBucket: Identifiable {
        let id: Date
        let dayStart: Date
        let isToday: Bool
        let entries: [SubscriptionEntry]
    }

    private var dayBuckets: [DayBucket] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())

        var buckets: [Date: [SubscriptionEntry]] = [:]
        for entry in entries {
            guard let reset = entry.nextResetDate else { continue }
            let dayStart = cal.startOfDay(for: reset)
            let dayOffset = cal.dateComponents([.day], from: todayStart, to: dayStart).day ?? -1
            guard dayOffset >= 0, dayOffset <= Self.daysForward else { continue }
            buckets[dayStart, default: []].append(entry)
        }

        return (0...Self.daysForward).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: todayStart) else { return nil }
            let dayEntries = (buckets[day] ?? []).sorted {
                ($0.nextResetDate ?? .distantFuture) < ($1.nextResetDate ?? .distantFuture)
            }
            return DayBucket(
                id: day,
                dayStart: day,
                isToday: offset == 0,
                entries: dayEntries
            )
        }
    }

    private var totalResetCount: Int {
        dayBuckets.reduce(0) { $0 + $1.entries.count }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            header
            mercuryHairline
                .frame(height: 1)

            timelineGrid
                .padding(DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.40), lineWidth: 0.5)
                )
        }
        .padding(DesignSystem.Spacing.lg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quota reset atlas, next 7 days")
    }

    private var header: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("RESET ATLAS · NEXT 7 DAYS")
                .font(DesignSystem.Typography.monoTiny)
                .tracking(1.0)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            Spacer()

            if totalResetCount == 0 {
                Text("No resets scheduled in this window")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            } else {
                Text("\(totalResetCount) reset event\(totalResetCount == 1 ? "" : "s")")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
    }

    private var timelineGrid: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(dayBuckets) { bucket in
                dayColumn(bucket)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .overlay(alignment: .leading) {
                        if !bucket.isToday {
                            Rectangle()
                                .fill(DesignSystem.Colors.borderSubtle.opacity(0.55))
                                .frame(width: 0.5)
                                .padding(.vertical, 2)
                        }
                    }
            }
        }
    }

    // MARK: Day column

    @ViewBuilder
    private func dayColumn(_ bucket: DayBucket) -> some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            dayHeader(bucket)

            if bucket.entries.isEmpty {
                emptyDayMarker
            } else {
                VStack(spacing: 6) {
                    ForEach(bucket.entries) { entry in
                        resetCell(entry: entry)
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func dayHeader(_ bucket: DayBucket) -> some View {
        VStack(spacing: 2) {
            Text(dayLabel(for: bucket))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(
                    bucket.isToday
                        ? DesignSystem.Colors.ember
                        : DesignSystem.Colors.textMuted
                )

            Circle()
                .fill(
                    bucket.isToday
                        ? DesignSystem.Colors.ember.opacity(0.85)
                        : DesignSystem.Colors.textMuted.opacity(0.35)
                )
                .frame(width: 4, height: 4)
        }
    }

    private var emptyDayMarker: some View {
        Text("—")
            .font(DesignSystem.Typography.monoTiny)
            .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.45))
            .padding(.top, 4)
            .accessibilityHidden(true)
    }

    // MARK: Reset cell

    private func resetCell(entry: SubscriptionEntry) -> some View {
        let theme = ProviderTheme.theme(for: entry.provider)
        return VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.primaryColor.opacity(0.22),
                                theme.accentColor.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .stroke(theme.primaryColor.opacity(0.34), lineWidth: 0.75)
                ProviderLogoView(provider: entry.provider, size: 14, useFallbackColor: false)
            }
            .frame(width: 24, height: 24)
            .shadow(color: theme.primaryColor.opacity(0.22), radius: 2.5, y: 0)

            Text(timeLabel(for: entry))
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 2)
        .help(tooltipText(for: entry))
        .accessibilityLabel(
            "\(entry.provider.displayName) resets \(entry.nextResetDate?.formatted(date: .abbreviated, time: .shortened) ?? "later")"
        )
    }

    // MARK: Formatting helpers

    private func dayLabel(for bucket: DayBucket) -> String {
        if bucket.isToday { return "TODAY" }
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f.string(from: bucket.dayStart).uppercased()
    }

    private func timeLabel(for entry: SubscriptionEntry) -> String {
        guard let date = entry.nextResetDate else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f.string(from: date)
    }

    private func tooltipText(for entry: SubscriptionEntry) -> String {
        guard let date = entry.nextResetDate else {
            return "\(entry.provider.displayName) — \(entry.accountLabel)"
        }
        return """
        \(entry.provider.displayName) — \(entry.accountLabel)
        Resets \(date.formatted(.relative(presentation: .numeric)))
        \(date.formatted(date: .abbreviated, time: .shortened))
        """
    }

    private var mercuryHairline: some View {
        LinearGradient(
            colors: [
                DesignSystem.Colors.hermesMercury.opacity(0.0),
                DesignSystem.Colors.hermesMercury.opacity(0.55),
                DesignSystem.Colors.hermesAureate.opacity(0.65),
                DesignSystem.Colors.hermesMercury.opacity(0.55),
                DesignSystem.Colors.hermesMercury.opacity(0.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
