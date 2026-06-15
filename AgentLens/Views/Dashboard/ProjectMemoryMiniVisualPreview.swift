import Charts
import SwiftUI

struct MiniVisualPreview: View {
    let visual: ProjectMemoryVisual

    var body: some View {
        Group {
            if visual.kind == .timeline {
                Chart {
                    ForEach(Array(visual.points.enumerated()), id: \.offset) { idx, p in
                        LineMark(x: .value("i", idx), y: .value("v", p.value))
                            .foregroundStyle(DesignSystem.Colors.hermesAureate)
                            .interpolationMethod(.catmullRom)
                    }
                }
            } else {
                Chart {
                    ForEach(Array(visual.points.prefix(6).enumerated()), id: \.offset) { idx, p in
                        BarMark(x: .value("i", idx), y: .value("v", p.value))
                            .foregroundStyle(barColor(idx))
                            .cornerRadius(2)
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .accessibilityHidden(true)
    }

    private func barColor(_ idx: Int) -> Color {
        let palette: [Color] = [
            DesignSystem.Colors.hermesAureate,
            DesignSystem.Colors.whimsy,
            DesignSystem.Colors.ember,
            DesignSystem.Colors.amber,
            DesignSystem.Colors.hermesMercury
        ]
        return palette[idx % palette.count]
    }
}
