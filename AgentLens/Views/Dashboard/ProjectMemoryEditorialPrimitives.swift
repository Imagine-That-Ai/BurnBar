import Charts
import OpenBurnBarCore
import SwiftUI

// remediation(ProjectsView-decomposition): Relocated cohesive "Editorial
// Observatory" reading primitives out of the 4,388-line ProjectsView.swift to
// shrink that file. Behavior-preserving move only — no logic changes. These
// types were `private` nested in ProjectsView.swift; their access is widened to
// internal so they stay visible within the module. They depend on the Wiki
// primitives (WikiQuery / WikiPivotPillRow) relocated to
// ProjectMemoryWikiPrimitives.swift and on DesignSystem / Formatting helpers,
// all in the same module.

struct EditorialHero: View {
    let eyebrow: String
    let subtitle: String?
    let headline: String
    let metaSegments: [String]
    let leadAccent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "scroll.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(leadAccent)
                Text(eyebrow.uppercased())
                    .font(DesignSystem.Typography.caption)
                    .tracking(2.0)
                    .foregroundStyle(leadAccent)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(headline)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if !metaSegments.isEmpty {
                Text(metaSegments.joined(separator: "  ·  "))
                    .font(DesignSystem.Typography.monoSmall)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            MercuryHairline()
                .padding(.top, DesignSystem.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MercuryHairline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(DesignSystem.Colors.mercuryGradient)
                    .frame(height: 0.5)
                if !reduceMotion {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignSystem.Colors.hermesMercury.opacity(0.0),
                                    DesignSystem.Colors.hermesAureate.opacity(0.55),
                                    DesignSystem.Colors.hermesMercury.opacity(0.0)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(40, w * 0.18), height: 0.5)
                        .offset(x: phase * w)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: 0.5, alignment: .leading)
            .clipped()
        }
        .frame(height: 0.5)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 3.0)) { phase = 1 }
        }
    }
}

struct HermesReadingCard: View {
    let title: String
    let placeholder: String
    let controller: ProjectMemoryInsightController
    var onRetry: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            content
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.mercuryGradient, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hermes reading")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        switch controller.state {
        case .idle: return placeholder
        case .streaming where controller.streamingContent.isEmpty: return "Hermes is reading the evidence."
        case .streaming: return controller.streamingContent
        case .complete: return controller.streamingContent
        case .failed(let err): return "Failed. " + err
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: headerIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
            Text(title.uppercased())
                .font(DesignSystem.Typography.caption)
                .tracking(2.0)
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
            Spacer(minLength: 0)
            trailingControl
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch controller.state {
        case .streaming:
            MercuryPoolDots()
        case .failed:
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderless)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
            } else {
                EmptyView()
            }
        case .idle, .complete:
            EmptyView()
        }
    }

    private var headerIcon: String {
        switch controller.state {
        case .failed: return "exclamationmark.triangle.fill"
        default:      return "sparkles"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            Text(placeholder)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .streaming where controller.streamingContent.isEmpty:
            Text(placeholder)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .streaming:
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(controller.streamingContent)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: controller.streamingContent)
                MercuryCaret()
            }
        case .complete:
            Text(controller.streamingContent)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let err):
            VStack(alignment: .leading, spacing: 6) {
                Text(err)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If Hermes isn't running, the indexed evidence below is still authoritative.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }
}

struct MercuryPoolDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var t: Double = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(DesignSystem.Colors.mercuryGradient)
                    .frame(width: 6, height: 6)
                    .scaleEffect(scale(at: i))
                    .opacity(opacity(at: i))
            }
        }
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                t = 1
            }
        }
    }

    private func scale(at i: Int) -> CGFloat {
        let start: [CGFloat] = [1.0, 0.8, 1.0]
        let target: [CGFloat] = [1.4, 1.0, 0.8]
        return start[i] + (target[i] - start[i]) * CGFloat(t)
    }

    private func opacity(at i: Int) -> Double {
        let start: [Double] = [0.55, 1.0, 0.6]
        let target: [Double] = [1.0, 0.55, 1.0]
        return start[i] + (target[i] - start[i]) * t
    }
}

struct MercuryCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.hermesAureate)
            .frame(width: 6, height: 14)
            .opacity(visible ? 1 : 0.2)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    visible.toggle()
                }
            }
    }
}

struct NumberedSectionRow: View {
    let index: Int
    let total: Int
    let title: String
    let text: String
    let accent: Color
    let citations: [ProjectMemoryCitation]
    let onCitationTap: (ProjectMemoryCitation) -> Void
    let onCombinedCitationTap: (() -> Void)?
    var pivotQueries: [WikiQuery] = []
    var onPivotTap: ((WikiQuery) -> Void)?

    private var trimmedBody: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSentinelBody: Bool {
        let lowered = trimmedBody.lowercased()
        let sentinels = [
            "no indexed conversations are available yet",
            "no explicit decision summaries were found yet",
            "no key-file evidence found yet",
            "no reusable commands captured yet",
            "no unresolved risk language captured yet"
        ]
        return sentinels.contains(where: { lowered.hasPrefix($0) }) || trimmedBody.count < 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text(String(format: "%02d", index))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
                Text("\(index) / \(total)")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            if isSentinelBody {
                EmptyEvidenceCallout(message: trimmedBody)
            } else {
                Text(trimmedBody)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !pivotQueries.isEmpty, let onPivotTap {
                WikiPivotPillRow(queries: pivotQueries, onTap: onPivotTap)
                    .padding(.top, 2)
            }
            if !citations.isEmpty {
                citationStrip
            }
        }
        .padding(.leading, DesignSystem.Spacing.md + 3 + DesignSystem.Spacing.sm)
        .padding(.trailing, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accent)
                .frame(width: 3)
                .padding(.leading, DesignSystem.Spacing.md)
                .padding(.vertical, 1)
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(index) of \(total). \(title)")
        .accessibilityValue(isSentinelBody ? "Insufficient evidence" : trimmedBody)
    }

    @ViewBuilder
    private var citationStrip: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: 6) {
                Text("FOOTNOTES")
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.4)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                if let onCombinedCitationTap {
                    Button {
                        onCombinedCitationTap()
                    } label: {
                        Text("Read all \(citations.count) →")
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            HFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(citations.prefix(8).enumerated()), id: \.element.id) { idx, citation in
                    FootnoteCitationChip(
                        ordinal: idx + 1,
                        citation: citation,
                        onTap: { onCitationTap(citation) }
                    )
                }
            }
        }
    }
}

struct FootnoteCitationChip: View {
    let ordinal: Int
    let citation: ProjectMemoryCitation
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(String(format: "[%02d]", ordinal))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                Text(citation.title.isEmpty ? citation.sourceKind.rawValue : citation.title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(hovered ? 0.95 : 0.55))
            )
            .overlay(
                Capsule()
                    .stroke(
                        hovered ? DesignSystem.Colors.hermesAureate.opacity(0.5) : DesignSystem.Colors.borderSubtle,
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(hovered ? 1.02 : 1.0)
        .animation(DesignSystem.Animation.hover, value: hovered)
        .onHover { hovered = $0 }
        .accessibilityLabel("Footnote \(ordinal): \(citation.title)")
        .accessibilityHint("Opens Hermes analysis of this citation")
    }
}

struct EmptyEvidenceCallout: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.warning)
                Text("INSUFFICIENT EVIDENCE")
                    .font(DesignSystem.Typography.monoTiny)
                    .tracking(1.6)
                    .foregroundStyle(DesignSystem.Colors.warning)
            }
            Text(message.isEmpty ? "This section needs more indexed conversations before it can synthesize a meaningful answer." : message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Run Refresh Memory on the project to regenerate this section.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .italic()
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(DesignSystem.Colors.warning.opacity(0.25), lineWidth: 0.5)
        )
    }
}

struct CitationQuoteCard: View {
    let ordinal: Int
    let citation: ProjectMemoryCitation

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Text(String(format: "%02d", ordinal))
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
                .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Text(citation.title.isEmpty ? "Untitled" : citation.title)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    sourceChip
                }
                Text(citation.snippet.isEmpty ? "(no snippet captured)" : citation.snippet)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let createdAt = citation.createdAt {
                    Text(createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.75)
        )
        .accessibilityElement(children: .combine)
    }

    private var sourceChip: some View {
        Text(sourceLabel)
            .font(DesignSystem.Typography.monoTiny)
            .tracking(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(DesignSystem.Colors.hermesAureate.opacity(0.12))
            )
            .overlay(
                Capsule().stroke(DesignSystem.Colors.hermesAureate.opacity(0.35), lineWidth: 0.5)
            )
            .foregroundStyle(DesignSystem.Colors.hermesAureate)
    }

    private var sourceLabel: String {
        switch citation.sourceKind {
        case .conversation:    return "TRANSCRIPT"
        case .skillDoc:        return "SKILL DOC"
        case .agentDoc:        return "AGENT DOC"
        case .sharedArtifact:  return "SHARED ARTIFACT"
        }
    }
}

struct VisualChart: View {
    let visual: ProjectMemoryVisual
    let sortAscending: Bool

    private var points: [ProjectMemoryVisualPoint] {
        visual.points.sorted { sortAscending ? $0.value < $1.value : $0.value > $1.value }
    }

    var body: some View {
        Group {
            if visual.kind == .timeline {
                Chart {
                    ForEach(Array(visual.points.enumerated()), id: \.offset) { idx, point in
                        LineMark(
                            x: .value("Bucket", idx),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        .interpolationMethod(.catmullRom)
                        PointMark(
                            x: .value("Bucket", idx),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text(Int(point.value).formatAsTokenVolume())
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                    }
                }
            } else {
                Chart {
                    ForEach(Array(points.enumerated()), id: \.offset) { idx, point in
                        BarMark(
                            x: .value("Label", point.label),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(barColor(at: idx))
                        .cornerRadius(4)
                        .annotation(position: .top, alignment: .center, spacing: 2) {
                            Text(valueLabel(point))
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }
                }
            }
        }
        .frame(height: 220)
        .chartXAxis {
            AxisMarks(values: .automatic) { _ in
                AxisGridLine().foregroundStyle(DesignSystem.Colors.borderSubtle)
                AxisValueLabel()
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(DesignSystem.Colors.borderSubtle)
                AxisValueLabel()
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .accessibilityLabel("Chart of \(visual.title)")
        .accessibilityValue("\(visual.points.count) data points")
    }

    private func barColor(at idx: Int) -> Color {
        let palette: [Color] = [
            DesignSystem.Colors.hermesAureate,
            DesignSystem.Colors.whimsy,
            DesignSystem.Colors.ember,
            DesignSystem.Colors.amber,
            DesignSystem.Colors.hermesMercury
        ]
        return palette[idx % palette.count]
    }

    private func valueLabel(_ point: ProjectMemoryVisualPoint) -> String {
        if let s = point.subtitle, !s.isEmpty { return s }
        if visual.kind == .providerMix { return point.value.formatAsCost() }
        if visual.kind == .timeline { return Int(point.value).formatAsTokenVolume() }
        return String(Int(point.value))
    }
}

struct CascadeInModifier: ViewModifier {
    let index: Int
    let visible: Int
    let reduceMotion: Bool

    // Cascade-in must never hide content — content rendering is always
    // synchronous; the modifier is now a no-op so a stalled cascade
    // Task (e.g. when the MainActor is busy assembling the Hermes
    // system prompt) can't trap the sheet in an invisible state. Keep
    // the parameters so call sites compile, but let the view through.
    func body(content: Content) -> some View {
        _ = (index, visible, reduceMotion)
        return content
    }
}

extension View {
    func cascadeIn(index: Int, visible: Int, reduceMotion: Bool) -> some View {
        modifier(CascadeInModifier(index: index, visible: visible, reduceMotion: reduceMotion))
    }
}

struct HFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if rowWidth + size.width > width, rowWidth > 0 {
                totalHeight += rowHeight + verticalSpacing
                rowHeight = size.height
                rowWidth = size.width + horizontalSpacing
            } else {
                rowWidth += size.width + horizontalSpacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: width.isFinite ? width : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
