import SwiftUI

// MARK: - QuotaResetAtlas
//
// 7-day horizontal timeline plotting the next reset event for each
// subscription. Each row is a provider lane; orbs sit along the time axis
// at their reset moment. Days where every plan has headroom render as a
// soft "open" band so the user can see when they'll have wide-open capacity.

struct QuotaResetAtlas: View {
    let entries: [SubscriptionEntry]

    private static let daysForward = 7
    private var window: ClosedRange<Date> {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: Self.daysForward, to: now) ?? now
        return now...end
    }

    private var laneEntries: [SubscriptionEntry] {
        entries.filter { entry in
            guard let reset = entry.nextResetDate else { return false }
            return window.contains(reset)
        }
    }

    private var dayTicks: [Date] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        return (0...Self.daysForward).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: start)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text("RESET ATLAS · NEXT 7 DAYS")
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.0)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                Spacer()

                if laneEntries.isEmpty {
                    Text("No resets scheduled in this window")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    Text("\(laneEntries.count) reset event\(laneEntries.count == 1 ? "" : "s")")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }

            mercuryHairline
                .frame(height: 1)

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    // Day grid + labels
                    HStack(spacing: 0) {
                        ForEach(Array(dayTicks.enumerated()), id: \.offset) { idx, day in
                            VStack(spacing: 4) {
                                Rectangle()
                                    .fill(DesignSystem.Colors.borderSubtle.opacity(idx == 0 ? 0 : 0.5))
                                    .frame(width: 0.5)
                                    .frame(maxHeight: .infinity, alignment: .top)
                                    .overlay(alignment: .top) {
                                        Text(dayLabel(for: day, isFirst: idx == 0))
                                            .font(DesignSystem.Typography.monoTiny)
                                            .foregroundStyle(DesignSystem.Colors.textMuted)
                                            .padding(.top, 2)
                                    }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    // Plot orbs
                    ForEach(laneEntries) { entry in
                        if let xPosition = xPosition(for: entry, in: geo.size.width) {
                            orbMarker(entry: entry)
                                .position(
                                    x: xPosition,
                                    y: geo.size.height - 22
                                )
                        }
                    }
                }
            }
            .frame(height: 140)
            .padding(.horizontal, DesignSystem.Spacing.sm)
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

    private func orbMarker(entry: SubscriptionEntry) -> some View {
        let theme = ProviderTheme.theme(for: entry.provider)
        return VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.primaryColor.opacity(0.20),
                                theme.accentColor.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle()
                    .stroke(theme.primaryColor.opacity(0.30), lineWidth: 0.75)
                ProviderLogoView(provider: entry.provider, size: 16, useFallbackColor: false)
            }
            .frame(width: 28, height: 28)
            .shadow(color: theme.primaryColor.opacity(0.25), radius: 3, y: 0)

            Text(entry.accountLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 64)
        }
        .help(tooltipText(for: entry))
        .accessibilityLabel("\(entry.provider.displayName) resets \(entry.nextResetDate?.formatted(date: .abbreviated, time: .shortened) ?? "later")")
    }

    private func tooltipText(for entry: SubscriptionEntry) -> String {
        guard let date = entry.nextResetDate else {
            return "\(entry.provider.displayName) — \(entry.accountLabel)"
        }
        return "\(entry.provider.displayName) (\(entry.accountLabel))\nResets \(date.formatted(.relative(presentation: .numeric)))\n\(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func dayLabel(for date: Date, isFirst: Bool) -> String {
        if isFirst { return "Now" }
        let f = DateFormatter()
        f.dateFormat = "EEE d"
        return f.string(from: date).uppercased()
    }

    private func xPosition(for entry: SubscriptionEntry, in width: CGFloat) -> CGFloat? {
        guard let date = entry.nextResetDate else { return nil }
        let total = window.upperBound.timeIntervalSince(window.lowerBound)
        guard total > 0 else { return nil }
        let elapsed = date.timeIntervalSince(window.lowerBound)
        let frac = max(0, min(1, elapsed / total))
        return CGFloat(frac) * width
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
