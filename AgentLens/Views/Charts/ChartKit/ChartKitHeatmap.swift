import SwiftUI

// MARK: - ChartKit · Heatmap
//
// 7×24 weekday × hour intensity grid. Static drawing at rest; hovering a
// cell outlines it and swaps the caption under the grid to that cell's
// reading (the caption defaults to the window's peak).

struct ChartKitHeatmap: View {
    /// `matrix[weekdayIndex][hour]`; row 0 = Sunday.
    let matrix: [[Double]]
    var accent: Color = DesignSystem.Colors.ember
    var valueFormatter: (Double) -> String = { $0.formatAsCost() }

    @State private var hovered: (weekday: Int, hour: Int)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private static let weekdayLabels = ["S", "M", "T", "W", "T", "F", "S"]
    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

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
                        let isHovered = hovered?.weekday == weekday && hovered?.hour == hour
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(fill(for: value, peak: peak))
                            .overlay {
                                if isHovered {
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .stroke(accent, lineWidth: 1.5)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                            .opacity(appeared ? 1 : 0)
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
            ChartKitReadout(text: caption(peak: peak), accent: accent)
                .padding(.top, 2)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            gridSize = newSize
        }
        .onAppear {
            if reduceMotion {
                appeared = true
            } else {
                withAnimation(.easeOut(duration: 0.5)) { appeared = true }
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                hovered = cellIndex(at: location)
            case .ended:
                hovered = nil
            }
        }
    }

    // MARK: Caption

    private func caption(peak: Double) -> String {
        if let hovered {
            let value = cell(weekday: hovered.weekday, hour: hovered.hour)
            let day = Self.weekdayNames[hovered.weekday]
            return value > 0
                ? "\(day) \(hourLabel(hovered.hour)) · \(valueFormatter(value))"
                : "\(day) \(hourLabel(hovered.hour)) · quiet"
        }
        if let peakCell = peakCell(), peak > 0.0001 {
            return "Peak: \(Self.weekdayNames[peakCell.weekday]) \(hourLabel(peakCell.hour)) · \(valueFormatter(peakCell.value))"
        }
        return "Hover a cell to read it"
    }

    private func peakCell() -> (weekday: Int, hour: Int, value: Double)? {
        var best: (weekday: Int, hour: Int, value: Double)?
        for (weekday, hours) in matrix.enumerated() {
            for (hour, value) in hours.enumerated() where value > (best?.value ?? 0) {
                best = (weekday, hour, value)
            }
        }
        return best
    }

    // MARK: Hit math

    /// Maps a pointer location to a cell. The grid is 7 rows × 24 square
    /// cells with a weekday-label gutter and 3pt gaps; the container size is
    /// tracked via `onGeometryChange` above.
    @State private var gridSize: CGSize = .zero

    private func cellIndex(at location: CGPoint) -> (weekday: Int, hour: Int)? {
        let size = gridSize
        guard size.width > 0, size.height > 0 else { return nil }
        // Cell geometry mirrors the layout above: 13pt label gutter, 3pt
        // gaps, 24 square cells per row.
        let gutter: CGFloat = 13
        let cellWidth = (size.width - gutter - 23 * 3) / 24
        guard cellWidth > 0, location.x >= gutter else { return nil }
        let hour = Int((location.x - gutter) / (cellWidth + 3))
        let weekday = Int(location.y / (cellWidth + 3))
        guard (0..<24).contains(hour), (0..<7).contains(weekday) else { return nil }
        return (weekday, hour)
    }

    private func cell(weekday: Int, hour: Int) -> Double {
        guard weekday < matrix.count, hour < matrix[weekday].count else { return 0 }
        return matrix[weekday][hour]
    }

    private func fill(for value: Double, peak: Double) -> Color {
        guard value > 0 else { return DesignSystem.Colors.surface.opacity(0.55) }
        // Sqrt keeps mid-range activity visible instead of letting one
        // monster hour wash everything else out.
        let intensity = (value / peak).squareRoot()
        return accent.opacity(0.14 + 0.78 * intensity)
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
