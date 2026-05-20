import SwiftUI
import OpenBurnBarCore

// MARK: - Pretext Playground
//
// Utility-first surface for users to feel how pretext lays text out.
// Three modes:
//   - Measure: paragraph height + line breaking at a chosen width
//   - Shrink:  binary-search the tightest width that fits a target line count
//   - Rich:    `@mention` and `` `code span `` fragments laid out inline
//
// Visually we go cardless. The text being laid out is the anchor; controls
// are reduced to a band of compact sliders + chips so the eye stays on the
// rendered output. Mercury accent used sparingly on read-outs and the active
// segmented mode pill.

struct PretextPlayground: View {
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .measure
    @State private var sampleText: String = Self.defaultSample
    @State private var maxWidth: CGFloat = 280
    @State private var lineHeight: CGFloat = 22
    @State private var fontSize: CGFloat = 16
    @State private var targetLines: Int = 3
    @State private var preWrap: Bool = false

    @State private var measureResult: PretextLinesResult? = nil
    @State private var shrinkWidth: CGFloat? = nil
    @State private var naturalWidth: CGFloat? = nil
    @State private var measurementInflight: Bool = false
    @State private var measurementError: String? = nil

    enum Mode: String, CaseIterable, Identifiable {
        case measure = "Measure"
        case shrink = "Shrink"
        case rich = "Rich"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        masthead
                        modePicker
                        liveSurface
                        readouts
                        controls
                        textEditor
                        Color.clear.frame(height: 32)
                    }
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.top, 16)
                }
            }
            .navigationTitle("Text Layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        sampleText = Self.defaultSample
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .accessibilityLabel("Reset sample text")
                }
            }
        }
        .task(id: measureKey) {
            await runMeasurement()
        }
    }

    // MARK: - Masthead
    //
    // Cardless brand-first headline. Single big "what is this" line, single
    // utility subtitle. No card chrome — the type does the work.

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pretext")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Watch text layout without the DOM.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        HStack(spacing: 8) {
            ForEach(Mode.allCases) { entry in
                Button {
                    if mode != entry {
                        HapticBus.toggle()
                        withAnimation(AuroraDesign.Motion.auroraSpring) {
                            mode = entry
                        }
                    }
                } label: {
                    Text(entry.rawValue)
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(mode == entry ? .white : MobileTheme.Colors.textSecondary)
                        .background(
                            Capsule().fill(
                                mode == entry
                                    ? AnyShapeStyle(AuroraDesign.Gradients.mercuryFoil)
                                    : AnyShapeStyle(MobileTheme.Colors.surface.opacity(0.6))
                            )
                        )
                        .overlay(
                            Capsule().stroke(
                                mode == entry
                                    ? .white.opacity(0.18)
                                    : MobileTheme.Colors.border.opacity(0.4),
                                lineWidth: 0.5
                            )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Live Surface
    //
    // The anchor visual. A clear viewport showing the text laid out, with a
    // dotted guideline at the active maxWidth. No card frame — just a quiet
    // background tone separating it from the masthead.

    private var liveSurface: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(MobileTheme.Colors.surface.opacity(0.6))

                widthGuide(in: proxy.size.width)

                surfaceContent(in: proxy.size.width)
                    .padding(.horizontal, surfacePadding)
                    .padding(.vertical, 18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 0.5)
            )
        }
        .frame(height: surfaceHeight)
    }

    private var surfacePadding: CGFloat { 16 }

    private var surfaceHeight: CGFloat {
        // Reserve enough room for ~10 lines so the user can see wrap variation
        // without internal scrolling at default sizes.
        max(240, lineHeight * 8 + 60)
    }

    @ViewBuilder
    private func surfaceContent(in available: CGFloat) -> some View {
        switch mode {
        case .measure:
            PretextTextView(
                sampleText,
                size: fontSize,
                lineHeight: lineHeight,
                maxWidth: clampedMaxWidth(in: available - surfacePadding * 2),
                options: pretextOptions
            )
        case .shrink:
            PretextTextView(
                sampleText,
                size: fontSize,
                lineHeight: lineHeight,
                maxWidth: shrinkWidth ?? clampedMaxWidth(in: available - surfacePadding * 2),
                shrink: true,
                shrinkTargetLines: targetLines,
                options: pretextOptions
            )
        case .rich:
            PretextRichBubble(
                text: sampleText,
                baseSize: fontSize,
                baseColor: MobileTheme.Colors.textPrimary,
                mentionColor: MobileTheme.hermesAureate,
                codeColor: MobileTheme.Colors.textPrimary,
                codeBackground: MobileTheme.Colors.surfaceElevated,
                lineHeight: lineHeight
            )
            .frame(maxWidth: clampedMaxWidth(in: available - surfacePadding * 2), alignment: .leading)
        }
    }

    /// Dotted vertical guide rendered at the active width — gives the user
    /// a tangible sense of "this is the wrap boundary".
    @ViewBuilder
    private func widthGuide(in available: CGFloat) -> some View {
        let width = (mode == .shrink ? (shrinkWidth ?? maxWidth) : maxWidth)
            .clamped(to: 24...max(24, available - surfacePadding * 2))
        let x = surfacePadding + width
        Path { path in
            var y: CGFloat = 8
            while y < surfaceHeight - 8 {
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x, y: y + 4))
                y += 9
            }
        }
        .stroke(MobileTheme.hermesAureate.opacity(0.55), lineWidth: 1)
    }

    private func clampedMaxWidth(in available: CGFloat) -> CGFloat {
        min(max(maxWidth, 24), max(24, available))
    }

    // MARK: - Readouts
    //
    // Quietly typeset numbers. No cards. Mercury accent on values, secondary
    // on labels. The numbers are the fact; everything else is chrome.

    private var readouts: some View {
        HStack(alignment: .firstTextBaseline, spacing: 28) {
            stat(
                label: "Lines",
                value: lineCountValue,
                detail: "wrap count"
            )
            stat(
                label: "Height",
                value: heightValue,
                detail: "px tall"
            )
            stat(
                label: secondaryStatLabel,
                value: secondaryStatValue,
                detail: secondaryStatDetail
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(MobileTheme.hermesAureate)
                .monospacedDigit()
            Text(detail)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
    }

    private var lineCountValue: String {
        if measurementInflight, measureResult == nil { return "…" }
        return measureResult?.lineCount.formatted() ?? "—"
    }

    private var heightValue: String {
        if let h = measureResult?.height {
            return "\(Int(h.rounded()))"
        }
        return "—"
    }

    private var secondaryStatLabel: String {
        switch mode {
        case .measure: return "Width"
        case .shrink:  return "Shrink"
        case .rich:    return "Width"
        }
    }

    private var secondaryStatValue: String {
        switch mode {
        case .measure, .rich:
            return "\(Int(maxWidth.rounded()))"
        case .shrink:
            if let w = shrinkWidth { return "\(Int(w.rounded()))" }
            return "…"
        }
    }

    private var secondaryStatDetail: String {
        switch mode {
        case .measure: return "px max"
        case .shrink:  return "px tightest"
        case .rich:    return "px max"
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch mode {
            case .measure:
                slider("Max width", value: $maxWidth, range: 80...520, unit: "px")
                slider("Line height", value: $lineHeight, range: 14...40, unit: "px")
                slider("Font size", value: $fontSize, range: 11...28, unit: "pt")
                Toggle(isOn: $preWrap) {
                    Text("Preserve whitespace (pre-wrap)")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                }
                .tint(MobileTheme.hermesAureate)

            case .shrink:
                slider("Upper width", value: $maxWidth, range: 120...560, unit: "px")
                slider("Line height", value: $lineHeight, range: 14...40, unit: "px")
                slider("Font size", value: $fontSize, range: 11...28, unit: "pt")
                stepper(
                    "Target lines",
                    value: Binding(
                        get: { Double(targetLines) },
                        set: { targetLines = max(1, Int($0)) }
                    ),
                    range: 1...12,
                    step: 1,
                    detail: "\(targetLines) lines"
                )

            case .rich:
                slider("Max width", value: $maxWidth, range: 120...520, unit: "px")
                slider("Line height", value: $lineHeight, range: 14...40, unit: "px")
                slider("Font size", value: $fontSize, range: 11...28, unit: "pt")
                richHint
            }
        }
    }

    private var richHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inline syntax")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Text("Type @mentions and `code spans` directly in the text below to see how pretext keeps them atomic and breaks the rest of the line around them.")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func slider(
        _ label: String,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded())) \(unit)")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.hermesAureate)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
                .tint(MobileTheme.hermesAureate)
        }
    }

    private func stepper(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        detail: String
    ) -> some View {
        HStack {
            Text(label)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
            Spacer()
            Stepper(detail, value: value, in: range, step: step)
                .labelsHidden()
            Text(detail)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.hermesAureate)
        }
    }

    // MARK: - Text Editor
    //
    // Cardless multiline editor. Light surface, no chrome — looks like part
    // of the paper, not a control panel.

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sample text")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            TextEditor(text: $sampleText)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 110)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(MobileTheme.Colors.surface.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MobileTheme.Colors.border.opacity(0.5), lineWidth: 0.5)
                )

            if let measurementError {
                Text(measurementError)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.error)
            }
        }
    }

    // MARK: - Measurement task

    /// Stable key that triggers `task(id:)` to re-run measurement whenever
    /// the user changes a knob.
    private var measureKey: String {
        "\(mode.rawValue)|\(sampleText.hashValue)|\(maxWidth)|\(lineHeight)|\(fontSize)|\(targetLines)|\(preWrap)"
    }

    private var pretextOptions: PretextOptions {
        PretextOptions(whiteSpace: preWrap ? .preWrap : .normal)
    }

    private func runMeasurement() async {
        measurementInflight = true
        defer { measurementInflight = false }
        measurementError = nil
        guard !sampleText.isEmpty else {
            measureResult = nil
            shrinkWidth = nil
            naturalWidth = nil
            return
        }
        let canvasFont = "400 \(Int(fontSize))px -apple-system"
        do {
            let engine = PretextEngine.shared
            let prepared = try await engine.prepareWithSegments(
                text: sampleText,
                font: canvasFont,
                options: pretextOptions
            )
            switch mode {
            case .measure, .rich:
                let result = try await engine.layoutWithLines(
                    handle: prepared,
                    maxWidth: maxWidth,
                    lineHeight: lineHeight
                )
                self.measureResult = result
            case .shrink:
                let resolvedWidth = try await engine.shrinkWrapWidth(
                    handle: prepared,
                    upper: maxWidth,
                    targetLines: targetLines
                )
                self.shrinkWidth = resolvedWidth
                let result = try await engine.layoutWithLines(
                    handle: prepared,
                    maxWidth: resolvedWidth,
                    lineHeight: lineHeight
                )
                self.measureResult = result
            }
        } catch {
            measurementError = "Pretext is warming up — try again in a moment."
        }
    }

    // MARK: - Default sample

    private static let defaultSample: String = """
    Pretext is fast, accurate, and supports every language you didn't know about. Try editing this text, drag the sliders, watch the wrap points move.

    Mention @maya about the new `prepareWithSegments` flow — the rich-inline path keeps `@handles` and `code spans` atomic while the body prose breaks naturally between them.
    """
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

#Preview {
    PretextPlayground()
}
