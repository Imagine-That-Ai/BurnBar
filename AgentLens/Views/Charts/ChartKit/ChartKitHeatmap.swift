import SwiftUI

// MARK: - ChartKit · Heatmap
//
// 7×24 weekday × hour intensity grid. Static drawing only.

struct ChartKitHeatmap: View {
    /// `matrix[weekdayIndex][hour]`; row 0 = Sunday.
    let matrix: [[Double]]
    var accent: Color = DesignSystem.Colors.ember

    private static let weekdayLabels = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        let peak = max(matrix.flatMap { $0 }.max() ?? 0, 0.0001)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: 3) {
                    Text(Self.weekdayLabels[weekday])
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(width: 10)
                    ForEach(0..<24, id: \.self) { hour in
                        let value = cell(weekday: weekday, hour: hour)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(fill(for: value, peak: peak))
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer().frame(width: 10)
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text(hourLabel(hour))
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func cell(weekday: Int, hour: Int) -> Double {
        guard weekday < matrix.count, hour < matrix[weekday].count else { return 0 }
        return matrix[weekday][hour]
    }

    private func fill(for value: Double, peak: Double) -> Color {
        // Empty cells are a faint neutral lattice, so the ember heat reads as
        // signal against a calm grid rather than fighting a grey slab.
        guard value > 0 else { return DesignSystem.Colors.textPrimary.opacity(0.05) }
        // Sqrt keeps mid-range activity visible instead of letting one
        // monster hour wash everything else out.
        let intensity = (value / peak).squareRoot()
        return accent.opacity(0.16 + 0.74 * intensity)
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: return "12a"
        case 12: return "12p"
        case ..<12: return "\(hour)a"
        default: return "\(hour - 12)p"
        }
    }
}
