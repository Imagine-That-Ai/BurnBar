import SwiftUI

// MARK: - Calendar Day Cell
//
// One day in the month grid: the day number, a heatmap fill whose intensity
// tracks the month's peak day cost (the same sqrt-scaled idiom as
// `ChartKitHeatmap.fill(for:peak:)`), and a strip of up to three provider
// dots for the day's top spenders.

struct CalendarDayCell: View {
    let date: Date
    let cost: Double
    /// The visible month's peak day cost — the intensity denominator.
    let peak: Double
    let topProviders: [AgentProvider]
    let isInMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    var accent: Color = DesignSystem.Colors.ember
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter
    }()

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.dayFormatter.string(from: date))
                        .font(.system(
                            size: 11,
                            weight: isToday ? .bold : .medium,
                            design: .rounded
                        ))
                        .monospacedDigit()
                        .foregroundStyle(numberColor)
                    Spacer(minLength: 0)
                    if cost > 0 {
                        Text(cost.formatAsCost())
                            .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 2.5) {
                    ForEach(Array(topProviders.prefix(3).enumerated()), id: \.offset) { _, provider in
                        Circle()
                            .fill(DesignSystem.Colors.primary(for: provider))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(fillColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(ringColor, lineWidth: isSelected ? 1.5 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isInMonth ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Fill & rings

    /// Heatmap fill — sqrt keeps mid-range days visible instead of letting
    /// one monster day wash the rest out (same recipe as ChartKitHeatmap).
    private var fillColor: Color {
        if isSelected {
            return accent.opacity(colorScheme == .dark ? 0.34 : 0.24)
        }
        guard cost > 0, peak > 0 else {
            return DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.4 : 0.5)
        }
        let intensity = (cost / peak).squareRoot()
        return accent.opacity(0.10 + 0.55 * intensity)
    }

    private var ringColor: Color {
        if isSelected {
            return accent.opacity(0.85)
        }
        if isToday {
            return accent.opacity(0.55)
        }
        return DesignSystem.Colors.border.opacity(0.28)
    }

    private var numberColor: Color {
        if !isInMonth { return DesignSystem.Colors.textMuted }
        return isToday ? accent : DesignSystem.Colors.textPrimary
    }

    private var accessibilityText: String {
        var parts = [date.formatted(date: .complete, time: .omitted)]
        if cost > 0 { parts.append(cost.formatAsCost()) }
        if isToday { parts.append("Today") }
        return parts.joined(separator: ", ")
    }
}
