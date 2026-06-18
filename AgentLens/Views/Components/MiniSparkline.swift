import Charts
import SwiftUI

struct MiniSparkline: View {
    let data: [Double]
    var color: Color = DesignSystem.Colors.ember
    var width: CGFloat = 60
    var height: CGFloat = 20

    private var points: [(Int, Double)] {
        Array(data.enumerated())
    }

    var body: some View {
        Chart {
            ForEach(points, id: \.0) { index, value in
                // Area fill is declared first so it draws under the line.
                // Swift Charts paints in declaration order, so the crisp line
                // and the end-point cap must come last to sit on top.
                AreaMark(
                    x: .value("Day", index),
                    y: .value("Cost", value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.22), color.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Day", index),
                    y: .value("Cost", value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
            }
            if let last = points.last {
                PointMark(x: .value("Day", last.0), y: .value("Cost", last.1))
                    .foregroundStyle(color)
                    .symbolSize(12)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.frame(width: width, height: height)
        }
        .frame(width: width, height: height)
    }
}
