import SwiftUI
import Charts

public struct InsightDistributionView: View {
    public let data: InsightWidgetData.Distribution
    public let spec: InsightWidgetSpec
    public init(data: InsightWidgetData.Distribution, spec: InsightWidgetSpec) {
        self.data = data
        self.spec = spec
    }

    public var body: some View {
        switch style {
        case .donut, .pie:
            donutChart
        case .treemap:
            InsightTreemapView(slices: data.slices, valueFormat: data.valueFormat, total: data.total)
        }
    }

    private var style: InsightWidgetSpec.DistributionSpec.Style {
        if case .distribution(let s) = spec { return s.style }
        return .donut
    }

    private var donutChart: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.md) {
            Chart {
                ForEach(data.slices) { slice in
                    SectorMark(
                        angle: .value("Value", slice.value),
                        innerRadius: .ratio(style == .donut ? 0.55 : 0),
                        angularInset: 1
                    )
                    .foregroundStyle(InsightFormatting.color(forHex: slice.colorHex)
                                     ?? InsightFormatting.color(forSeriesID: slice.id))
                    .cornerRadius(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(data.slices.prefix(6)) { slice in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(InsightFormatting.color(forHex: slice.colorHex)
                                  ?? InsightFormatting.color(forSeriesID: slice.id))
                            .frame(width: 8, height: 8)
                        Text(slice.label)
                            .font(UnifiedDesignSystem.Typography.caption)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(InsightFormatting.format(slice.value, as: data.valueFormat))
                            .font(UnifiedDesignSystem.Typography.tiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    }
                }
            }
            .frame(minWidth: 110, alignment: .leading)
        }
    }
}

struct InsightTreemapView: View {
    let slices: [InsightWidgetData.Distribution.Slice]
    let valueFormat: ValueFormat
    let total: Double

    var body: some View {
        GeometryReader { proxy in
            let rects = squarify(slices: slices, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(rects.enumerated()), id: \.offset) { _, item in
                    let slice = item.slice
                    let rect = item.rect
                    let color = InsightFormatting.color(forHex: slice.colorHex)
                        ?? InsightFormatting.color(forSeriesID: slice.id)
                    Rectangle()
                        .fill(color.opacity(0.85))
                        .frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2))
                        .overlay(
                            VStack(alignment: .leading, spacing: 2) {
                                Text(slice.label)
                                    .font(UnifiedDesignSystem.Typography.caption)
                                    .lineLimit(1)
                                Text(InsightFormatting.format(slice.value, as: valueFormat))
                                    .font(UnifiedDesignSystem.Typography.tiny)
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .padding(6),
                            alignment: .topLeading
                        )
                        .foregroundStyle(.white)
                        .offset(x: rect.minX, y: rect.minY)
                        .cornerRadius(4)
                }
            }
        }
        .frame(minHeight: 160)
    }

    /// Naive squarified treemap layout.
    private func squarify(slices: [InsightWidgetData.Distribution.Slice], in rect: CGRect)
        -> [(slice: InsightWidgetData.Distribution.Slice, rect: CGRect)] {
        let total = slices.reduce(0) { $0 + max(0, $1.value) }
        guard total > 0 else { return [] }
        var result: [(InsightWidgetData.Distribution.Slice, CGRect)] = []
        var remaining = rect
        for slice in slices {
            let frac = slice.value / total
            if remaining.width > remaining.height {
                let w = remaining.width * frac
                result.append((slice, CGRect(x: remaining.minX, y: remaining.minY,
                                              width: w, height: remaining.height)))
                remaining.origin.x += w
                remaining.size.width -= w
            } else {
                let h = remaining.height * frac
                result.append((slice, CGRect(x: remaining.minX, y: remaining.minY,
                                              width: remaining.width, height: h)))
                remaining.origin.y += h
                remaining.size.height -= h
            }
        }
        return result
    }
}
