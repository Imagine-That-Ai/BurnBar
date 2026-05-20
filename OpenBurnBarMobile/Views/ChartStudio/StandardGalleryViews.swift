import SwiftUI

// MARK: - Quick Fact tile (small horizontal pill on the strip)

struct QuickFactTile: View {
    let fact: QuickFact

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fact.label)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.4)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            Text(fact.value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(toneColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 6) {
                if !fact.sparkline.isEmpty {
                    SparklineMini(values: fact.sparkline, accent: toneColor)
                        .frame(width: 56, height: 14)
                }
                Text(fact.detail)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(toneColor.opacity(0.35), lineWidth: 0.6)
        )
    }

    private var toneColor: Color {
        switch fact.tone {
        case .positive: return MobileTheme.success
        case .warning:  return MobileTheme.warning
        case .neutral:  return MobileTheme.hermesAureate
        }
    }
}

// MARK: - Sparkline (tiny line chart for fact tiles)

struct SparklineMini: View {
    let values: [Double]
    let accent: Color

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if values.count >= 2 {
                    let minV = values.min() ?? 0
                    let maxV = max(values.max() ?? 1, minV + 0.0001)
                    let dx = geo.size.width / Double(values.count - 1)
                    Path { path in
                        for (i, v) in values.enumerated() {
                            let x = Double(i) * dx
                            let normalized = (v - minV) / (maxV - minV)
                            let y = (1.0 - normalized) * geo.size.height
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(accent, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: - Gallery item card

struct GalleryItemCard: View {
    let item: StandardGalleryItem
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack(spacing: 8) {
                Text(item.category.uppercased())
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .foregroundStyle(categoryColor)
                Spacer()
                Button(action: onOpen) {
                    HStack(spacing: 4) {
                        Text("Open")
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(MobileTheme.hermesAureate)
                }
                .buttonStyle(.plain)
            }

            Text(item.headline)
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(item.blurb)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            galleryRendering
                .padding(.top, 0)
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AuroraDesign.Shape.heroCorner, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AuroraDesign.Shape.heroCorner, style: .continuous)
                .stroke(categoryColor.opacity(0.35), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var galleryRendering: some View {
        switch item.rendering {
        case .swiftChart(let spec):
            NativeChartView(spec: spec, displayMode: .gallery)
        case .ascii(let spec):
            AsciiCanvasView(spec: spec)
        case .insight(let spec):
            InsightCardView(spec: spec)
        case .mermaid(let spec):
            MermaidWebView(source: spec.source)
                .frame(minHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        case .composed(let items):
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, child in
                    nested(child)
                }
            }
        case .error(let msg):
            Text(msg)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.warning)
        }
    }

    @ViewBuilder
    private func nested(_ rendering: ChartStudioRendering) -> some View {
        switch rendering {
        case .swiftChart(let spec): NativeChartView(spec: spec, displayMode: .gallery)
        case .ascii(let spec):      AsciiCanvasView(spec: spec)
        case .insight(let spec):    InsightCardView(spec: spec)
        case .mermaid(let spec):    MermaidWebView(source: spec.source).frame(minHeight: 200)
        case .composed:             EmptyView()  // avoid recursion in cards
        case .error(let msg):       Text(msg).font(MobileTheme.Typography.caption).foregroundStyle(MobileTheme.warning)
        }
    }

    private var categoryColor: Color {
        switch item.category {
        case "Spend":    return MobileTheme.ember
        case "Mix":      return MobileTheme.whimsy
        case "Models":   return MobileTheme.amber
        case "Cache":    return MobileTheme.blaze
        case "Time":     return MobileTheme.hermesAureate
        case "Velocity": return MobileTheme.success
        default:         return MobileTheme.hermesAureate
        }
    }
}
