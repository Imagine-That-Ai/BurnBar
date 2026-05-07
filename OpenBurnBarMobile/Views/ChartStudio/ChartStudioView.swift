import SwiftUI
import OpenBurnBarCore

// MARK: - Chart Studio View
//
// Full-screen AI-driven canvas. Type → stream → render. Three render
// kinds (swift_chart, mermaid, insight) plus a `composed` stack. Recent
// canvases persist in `ChartStudioStore` and rehydrate on next launch.

struct ChartStudioView: View {
    let digest: TrendDataDigest
    let hermesService: HermesService
    let onClose: () -> Void

    @State private var store = ChartStudioStore()
    @State private var prompt: String = ""
    @FocusState private var promptFocused: Bool
    @State private var streamingText: String = ""
    @State private var rendering: ChartStudioRendering?
    @State private var isStreaming: Bool = false
    @State private var error: String?
    @State private var streamTask: Task<Void, Never>?
    @State private var lastSubmittedPrompt: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    init(digest: TrendDataDigest, hermesService: HermesService, onClose: @escaping () -> Void) {
        self.digest = digest
        self.hermesService = hermesService
        self.onClose = onClose
    }

    private var promptEngine: ChartStudioPromptEngine {
        ChartStudioPromptEngine(digest: digest)
    }

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .full)
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                        promptCarousel
                        canvas
                        if !store.canvases.isEmpty { recentStrip }
                        Spacer(minLength: MobileTheme.Spacing.xxxl)
                    }
                    .padding(.top, MobileTheme.Spacing.md)
                    .padding(.bottom, MobileTheme.Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)

                inputBar
                    .padding(.horizontal, MobileTheme.Spacing.lg)
                    .padding(.vertical, MobileTheme.Spacing.md)
                    .background(.ultraThinMaterial)
            }
        }
        .onDisappear {
            streamTask?.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Text("☿")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(MobileTheme.hermesAureate)
                .shadow(color: MobileTheme.hermesAureate.opacity(0.4), radius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text("Chart Studio")
                    .font(MobileTheme.Typography.title)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(reachableSubtitle)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            Spacer()
            Button {
                onClose()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Chart Studio")
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
        .padding(.vertical, MobileTheme.Spacing.md)
        .overlay(alignment: .bottom) {
            MercuryDivider()
        }
    }

    private var reachableSubtitle: String {
        if isStreaming { return "Drawing…" }
        if hermesService.isReachable { return "Hermes online · ask for any chart" }
        return "Hermes offline — start it on your Mac"
    }

    // MARK: - Prompt Carousel

    private var promptCarousel: some View {
        ChartStudioPromptCarousel(
            prompts: promptEngine.suggestedPrompts(),
            onSelect: { tapped in
                prompt = tapped
                submit()
            }
        )
    }

    // MARK: - Canvas

    private var canvas: some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.heroCorner, padding: AuroraDesign.Layout.heroPadding) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                if let error = error {
                    errorView(error)
                } else if let rendering = rendering {
                    renderingView(rendering)
                } else if isStreaming {
                    streamingView
                } else {
                    welcomeView
                }
            }
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }

    private func renderingView(_ rendering: ChartStudioRendering) -> AnyView {
        switch rendering {
        case .swiftChart(let spec):
            return AnyView(NativeChartView(spec: spec))
        case .mermaid(let spec):
            return AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    if let title = spec.title {
                        Text(title)
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                    }
                    MermaidWebView(source: spec.source)
                        .frame(minHeight: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(MobileTheme.hermesAureate.opacity(0.4), lineWidth: 0.5)
                        )
                }
            )
        case .insight(let spec):
            return AnyView(
                InsightCardView(spec: spec) { followUp in
                    prompt = followUp
                    submit()
                }
            )
        case .composed(let renderings):
            return AnyView(
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                    ForEach(Array(renderings.enumerated()), id: \.offset) { _, item in
                        renderingView(item)
                    }
                }
            )
        case .error(let message):
            return AnyView(errorView(message))
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MobileTheme.warning)
                Text("Studio couldn't draw that")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
            }
            Text(message)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let lastSubmittedPrompt {
                Button {
                    prompt = lastSubmittedPrompt
                    submit()
                } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(MobileTheme.Typography.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.aurora(.hermes))
                .padding(.top, 4)
            }
        }
    }

    private var streamingView: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(spacing: 8) {
                MercuryThinkingIndicator()
                Text("Hermes is drawing your chart…")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            if !streamingText.isEmpty {
                ScrollView {
                    Text(streamingText)
                        .font(MobileTheme.Typography.monoTiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(MobileTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MobileTheme.Colors.surface.opacity(0.4))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(MobileTheme.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                )
            }
        }
    }

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 20))
                    .foregroundStyle(AuroraDesign.Gradients.mercuryFoil)
                Text("Ask for any chart you want")
                    .font(MobileTheme.Typography.title)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
            }
            Text("Native Swift Charts, Mermaid diagrams, narrative insights — Hermes will pick the best canvas for your question.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                bullet("Stack daily cost by provider over the last 30 days")
                bullet("Mermaid sequence diagram of your last session")
                bullet("Heatmap of burn by hour-of-day")
                bullet("Compare cost-per-million-tokens across models")
            }
            .padding(.top, 4)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.hermesAureate)
            Text(text)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
    }

    // MARK: - Recent Strip

    private var recentStrip: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack {
                Text("RECENT CANVASES")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .tracking(1.6)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Spacer()
                Button {
                    store.clear()
                } label: {
                    Text("Clear")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.canvases) { canvas in
                        Button {
                            replay(canvas)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(canvas.title)
                                    .font(MobileTheme.Typography.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                                    .lineLimit(2)
                                Text(canvas.summary)
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(MobileTheme.Colors.textMuted)
                                    .lineLimit(2)
                                Text(canvas.createdAt, style: .relative)
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(MobileTheme.Colors.textMuted.opacity(0.7))
                            }
                            .padding(MobileTheme.Spacing.sm)
                            .frame(width: 200, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(MobileTheme.Colors.surface.opacity(0.6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(MobileTheme.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, MobileTheme.Spacing.lg)
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            TextField("Ask Hermes to draw…", text: $prompt, axis: .horizontal)
                .font(MobileTheme.Typography.body)
                .textFieldStyle(.plain)
                .focused($promptFocused)
                .onSubmit(submit)
                .padding(MobileTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(MobileTheme.Colors.surface.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            promptFocused ? MobileTheme.hermesAureate : MobileTheme.Colors.border.opacity(0.4),
                            lineWidth: promptFocused ? 1.0 : 0.5
                        )
                )
            Button(action: submit) {
                Image(systemName: isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(submitColor)
                    .symbolEffect(.bounce, value: isStreaming)
            }
            .buttonStyle(.plain)
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isStreaming)
            .accessibilityLabel(isStreaming ? "Stop drawing" : "Send prompt")
        }
    }

    private var submitColor: Color {
        if isStreaming { return MobileTheme.warning }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MobileTheme.Colors.textMuted
        }
        return MobileTheme.hermesAureate
    }

    // MARK: - Submit

    private func submit() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if isStreaming {
            streamTask?.cancel()
            isStreaming = false
            return
        }
        guard !trimmed.isEmpty else { return }
        HapticBus.send()
        promptFocused = false
        lastSubmittedPrompt = trimmed
        prompt = ""
        startStream(prompt: trimmed)
    }

    private func startStream(prompt: String) {
        rendering = nil
        error = nil
        streamingText = ""
        isStreaming = true

        let bridge = ChartStudioHermesBridge(service: hermesService)
        let system = promptEngine.systemPrompt()

        streamTask = Task { @MainActor in
            do {
                for try await event in bridge.send(prompt: prompt, systemPrompt: system) {
                    switch event {
                    case .partial(let text):
                        streamingText = text
                    case .completed(let text):
                        streamingText = text
                        let parsed = ChartSpecRenderer.decode(text)
                        rendering = parsed
                        persistCanvas(prompt: prompt, raw: text, rendering: parsed)
                    }
                }
            } catch is CancellationError {
                // user-cancelled; leave whatever's on screen
            } catch {
                self.error = error.localizedDescription
            }
            isStreaming = false
        }
    }

    private func persistCanvas(prompt: String, raw: String, rendering: ChartStudioRendering) {
        let title = titleFor(rendering: rendering, fallback: prompt)
        let summary = summaryFor(rendering: rendering)
        let renderingData = (try? JSONEncoder().encode(EnvelopeForArchive(rendering: rendering))) ?? Data()
        let canvas = ChartStudioCanvas(
            prompt: prompt,
            title: title,
            summary: summary,
            renderingJSON: renderingData
        )
        store.add(canvas)
    }

    private func titleFor(rendering: ChartStudioRendering, fallback: String) -> String {
        switch rendering {
        case .swiftChart(let s): return s.title
        case .mermaid(let m):    return m.title ?? "Mermaid diagram"
        case .insight(let i):    return i.title
        case .composed:          return "Composed canvas"
        case .error:             return fallback
        }
    }

    private func summaryFor(rendering: ChartStudioRendering) -> String {
        switch rendering {
        case .swiftChart(let s): return s.subtitle ?? "Native chart"
        case .mermaid:           return "Mermaid diagram"
        case .insight(let i):    return i.body
        case .composed:          return "Stacked rendering"
        case .error:             return "Couldn't draw"
        }
    }

    private func replay(_ canvas: ChartStudioCanvas) {
        guard let archive = try? JSONDecoder().decode(EnvelopeForArchive.self, from: canvas.renderingJSON) else { return }
        rendering = archive.toRendering()
        prompt = canvas.prompt
        error = nil
    }
}

// MARK: - Archive envelope

/// Lightweight Codable envelope so we can persist `ChartStudioRendering`
/// without needing the enum itself to be `Codable` (it has nested `composed`
/// recursion which complicates synthesis).
private struct EnvelopeForArchive: Codable {
    enum Kind: String, Codable { case swiftChart, mermaid, insight, composed, error }
    let kind: Kind
    let chart: ChartSpec?
    let mermaid: MermaidSpec?
    let insight: InsightSpec?
    let composed: [EnvelopeForArchive]?
    let errorMessage: String?

    init(rendering: ChartStudioRendering) {
        switch rendering {
        case .swiftChart(let s):
            kind = .swiftChart; chart = s; mermaid = nil; insight = nil; composed = nil; errorMessage = nil
        case .mermaid(let m):
            kind = .mermaid; chart = nil; mermaid = m; insight = nil; composed = nil; errorMessage = nil
        case .insight(let i):
            kind = .insight; chart = nil; mermaid = nil; insight = i; composed = nil; errorMessage = nil
        case .composed(let items):
            kind = .composed; chart = nil; mermaid = nil; insight = nil
            composed = items.map(EnvelopeForArchive.init(rendering:))
            errorMessage = nil
        case .error(let m):
            kind = .error; chart = nil; mermaid = nil; insight = nil; composed = nil; errorMessage = m
        }
    }

    func toRendering() -> ChartStudioRendering {
        switch kind {
        case .swiftChart: return chart.map(ChartStudioRendering.swiftChart) ?? .error("Missing chart spec.")
        case .mermaid:    return mermaid.map(ChartStudioRendering.mermaid)  ?? .error("Missing mermaid spec.")
        case .insight:    return insight.map(ChartStudioRendering.insight)  ?? .error("Missing insight spec.")
        case .composed:   return .composed((composed ?? []).map { $0.toRendering() })
        case .error:      return .error(errorMessage ?? "Unknown error.")
        }
    }
}
