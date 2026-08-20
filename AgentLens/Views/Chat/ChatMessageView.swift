import SwiftUI
import OpenBurnBarCore

// MARK: - Chat Message View

// The surface is deliberately close to nothing.
//
// Every message used to carry five layers of chrome — a lopsided speech-bubble
// silhouette, a surface fill, a tinted gradient wash, a glass material, a 1pt
// identity-coloured border and a coloured shadow — on *both* roles. Stacked
// down a transcript that reads as a wall of outlined cards competing with the
// prose inside them, and the assistant's identity hue (`F45B69`) framed every
// answer in a colour the eye reads as an error state.
//
// So the assistant turn has no container at all. It is prose on the canvas,
// which is what lets a long answer read as a document instead of a receipt.
// Only the user turn keeps a bubble: it is short, it is the thing you scan
// back for, and a shape is how you find it in a wall of text.
private enum ChatBubbleStyle {
    /// Symmetric. A lopsided silhouette reads as a speech tail at one corner
    /// and as a mistake at the other three.
    static func userShape() -> RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    /// Neutral by design. An identity tint here competes with the prose it is
    /// wrapping, and `Color.primary` inverts with the theme on its own, so one
    /// declaration is correct in both.
    static func userFill(_ colorScheme: ColorScheme) -> Color {
        Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.055)
    }
}

struct ChatMessageView: View {
    let message: ChatMessageRecord
    var isStreaming: Bool
    var showViaBadge: Bool
    var isHermes: Bool = false
    /// When set (e.g. Hermes `/v1/models`), shows vendor logo beside assistant turns.
    var assistantModelKey: String?
    /// Display mode: rich agent bubbles or raw CLI output.
    var viewMode: ChatViewMode = .agent
    /// F-3: memory citations to surface below this assistant turn (empty by
    /// default so existing call sites are unaffected). The chat view passes the
    /// controller's text-free citation projection for the latest turn.
    var memoryCitations: [MemoryCitation] = []
    /// F-3: jump callback for a same-device citation. When nil, jumpable chips
    /// render disabled (never a dead link).
    var onJumpToLocal: ((String) -> Void)?

    /// Live width of the agent bubble row, used to scale the opposite-side
    /// gutter so the reading column keeps a usable minimum on narrow panels
    /// (e.g. the 260pt floating chat) instead of losing 36pt to the gutter.
    @State private var agentRowWidth: CGFloat = 0

    @Environment(\.colorScheme) private var colorScheme

    private var transcript: [ChatTranscriptPiece] {
        message.displayTranscript
    }

    /// Opposite-side gutter for agent bubbles. Full 36pt breathing room on
    /// wide layouts, easing down to `Spacing.lg` (16pt) as the row narrows so
    /// the bubble's reading width isn't pinched on a 260pt floating panel.
    private var agentGutter: CGFloat {
        let wide: CGFloat = 36
        let narrow = DesignSystem.Spacing.lg
        guard agentRowWidth > 0 else { return wide }
        // Above ~480pt keep the full gutter; below ~300pt clamp to the narrow
        // floor; interpolate linearly between so it never snaps.
        let upper: CGFloat = 480
        let lower: CGFloat = 300
        if agentRowWidth >= upper { return wide }
        if agentRowWidth <= lower { return narrow }
        let t = (agentRowWidth - lower) / (upper - lower)
        return narrow + (wide - narrow) * t
    }

    private var lastProsePieceId: String? {
        transcript.last { piece in
            piece.kind == .text || piece.kind == .reasoning || piece.kind == .refusal
        }?.id
    }

    var body: some View {
        if viewMode == .cli {
            cliView
        } else {
            agentView
        }
    }

    // MARK: - CLI View

    @ViewBuilder
    private var cliView: some View {
        VStack(alignment: .leading, spacing: 2) {
            if message.role == .user {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    Text(">")
                        .font(DesignSystem.Typography.mono)
                        .foregroundStyle(DesignSystem.Colors.success)
                        .frame(width: 16, alignment: .trailing)
                    Text(message.content)
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    if let model = assistantModelKey?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                        ModelProviderLogoView(
                            modelKey: model,
                            size: 16,
                            fallbackSymbolColor: isHermes ? DesignSystem.Colors.hermesMercury : nil
                        )
                        .padding(.top, 1)
                    } else {
                        Text(isHermes ? "☿" : "<")
                            .font(DesignSystem.Typography.mono)
                            .foregroundStyle(isHermes ? DesignSystem.Colors.hermesAureate : DesignSystem.Colors.coral)
                            .frame(width: 16, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        if showViaBadge, let via = message.cliUsed {
                            Text(via == "hermes" ? "☿ via Hermes" : "via \(via)")
                                .font(DesignSystem.Typography.monoTiny)
                                .foregroundStyle(isHermes ? DesignSystem.Colors.hermesAureate : DesignSystem.Colors.textMuted)
                        }
                        Text(cliTranscriptText)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Plain-text representation for CLI view: interleaves tool markers into text.
    private var cliTranscriptText: String {
        let pieces = message.displayTranscript
        if pieces.isEmpty {
            return message.content
        }
        return pieces.map { piece in
            switch piece.kind {
            case .text:
                return piece.value
            case .reasoning:
                return "Reasoning\n\(piece.value)"
            case .refusal:
                return "Refusal\n\(piece.value)"
            case .toolUse:
                return "⟨\(piece.value)\(piece.detail.map { ": \($0)" } ?? "")⟩"
            case .toolResult:
                return piece.detail ?? piece.value
            }
        }.joined(separator: "\n")
    }

    // MARK: - Agent View (existing rich bubble rendering)

    @ViewBuilder
    private var agentView: some View {
        agentRowContent
            .background(
                // Background GeometryReader reports the row's available width
                // without affecting the HStack's own sizing (it fills the
                // background frame). Drives `agentGutter` so the gutter eases
                // down on narrow panels. macOS 14-safe (avoids macOS 15
                // `onGeometryChange`).
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: AgentRowWidthKey.self, value: proxy.size.width)
                }
            )
            .onPreferenceChange(AgentRowWidthKey.self) { width in
                if abs(width - agentRowWidth) > 0.5 {
                    agentRowWidth = width
                }
            }
    }

    /// The semantic agent-row tree, separated from the GeometryReader wrapper
    /// so tests can inspect message content without asking ViewInspector to
    /// synthesize a private GeometryProxy representation.
    @ViewBuilder
    var agentRowContent: some View {
        HStack(alignment: .bottom, spacing: DesignSystem.Spacing.sm) {
            if message.role == .user {
                Spacer(minLength: agentGutter)
                userProseBubble
            } else {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    if let raw = assistantModelKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                        // The one piece of plasma the transcript keeps. It is
                        // the only thing naming the speaker now that the turn
                        // has no container, so it earns the glass — and it is
                        // deliberately *still*: a drifting orb beside every
                        // message would be one animation clock per turn, and a
                        // transcript that never settles.
                        PlasmaOrb(
                            tint: isHermes
                                ? DesignSystem.Colors.hermesMercury
                                : DesignSystem.Colors.colorForModel(raw),
                            size: 26,
                            motion: .orbPrimary,
                            isAnimating: false
                        ) {
                            ModelProviderLogoView(
                                modelKey: raw,
                                size: 11,
                                fallbackSymbolColor: isHermes ? DesignSystem.Colors.hermesMercury : nil
                            )
                        }
                        .padding(.top, 1)
                    }
                    assistantTranscriptColumn
                }
                Spacer(minLength: agentGutter)
            }
        }
    }

    private var userProse: String {
        transcript.filter { $0.kind == .text }.map(\.value).joined()
    }

    @ViewBuilder
    private var userProseBubble: some View {
        let prose = userProse.isEmpty ? message.content : userProse
        VStack(alignment: .trailing, spacing: 6) {
            if !message.attachments.isEmpty {
                ChatAttachmentTray(
                    attachments: message.attachments,
                    isHermes: isHermes,
                    attachmentError: nil,
                    onRemove: nil,
                    onReveal: nil
                )
                .frame(maxWidth: 320, alignment: .trailing)
            }
            if !prose.isEmpty {
                proseBubble(
                    isUser: true,
                    text: prose,
                    appendCaret: false
                )
            }
        }
    }

    private var assistantTranscriptColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showViaBadge, let via = message.cliUsed {
                if via == "hermes" {
                    Text("\u{263F} via Hermes")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                } else {
                    Text("via \(via)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            // Hermes thinking state: show mercury droplets when streaming with no content yet
            if isHermes && isStreaming && transcript.isEmpty {
                HermesThinkingView()
            }

            ForEach(groupedTranscript) { group in
                Group {
                    switch group {
                    case .toolGroup(let pieces):
                        toolGroupStrip(pieces)
                    case .single(let piece):
                        switch piece.kind {
                        case .text:
                            proseBubble(
                                isUser: false,
                                text: piece.value,
                                appendCaret: isStreaming && piece.id == lastProsePieceId
                            )
                        case .reasoning, .refusal:
                            safetyLabeledBubble(
                                kind: piece.kind,
                                text: piece.value,
                                appendCaret: isStreaming && piece.id == lastProsePieceId
                            )
                        case .toolUse, .toolResult:
                            EmptyView()
                        }
                    }
                }
            }

            // F-3: surface memory citations below the assistant turn. Never a
            // dead link — the resolver degrades to cross-device / unavailable.
            if !memoryCitations.isEmpty {
                MemoryCitationChipView(citations: memoryCitations, onJumpToLocal: onJumpToLocal)
                    .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func safetyLabeledBubble(kind: ChatTranscriptPiece.Kind, text: String, appendCaret: Bool) -> some View {
        let title = kind == .reasoning ? "Reasoning" : "Refusal"
        let accent = kind == .reasoning ? DesignSystem.Colors.textMuted : DesignSystem.Colors.warning
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(accent)
            if !text.isEmpty || appendCaret {
                Text(text + (appendCaret ? "▍" : ""))
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm + 2)
        .padding(.vertical, DesignSystem.Spacing.xs + 2)
        .background(accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous))
    }

    // MARK: - Tool Group Strip

    /// One accordion summarising this group's tool calls. Pairs each
    /// `.toolUse` piece with the `.toolResult` that follows it so the
    /// expanded rows can show the result alongside the invocation.
    @ViewBuilder
    private func toolGroupStrip(_ pieces: [ChatTranscriptPiece]) -> some View {
        UnifiedToolCallAccordion(
            calls: unifiedToolCalls(from: pieces),
            accent: isHermes ? .hermes : .macAssistant
        )
    }

    /// Folds a transcript tool group into the shared display model, pairing a
    /// `.toolUse` with its following `.toolResult`. The final tool of a live
    /// turn pulses via `isRunning`; orphaned results are silently dropped.
    ///
    /// - Note: `HermesPopoverBubble.unifiedToolCalls(from:)` in
    ///   `HermesPopoverChatView.swift` mirrors this algorithm exactly. Keep
    ///   both in sync — `ChatTranscriptPiece` lives in AgentLens (not Core)
    ///   so the logic cannot be shared via `OpenBurnBarCore`.
    private func unifiedToolCalls(from pieces: [ChatTranscriptPiece]) -> [UnifiedToolCallDisplay] {
        // Track the last *unpaired* toolUse — that's the call still in flight
        // during a live stream. Using toolResult would fire isRunning on the
        // closing piece, which has already landed by definition.
        let lastUnpairedToolUseID: String? = {
            var id: String?
            var i = 0
            while i < pieces.count {
                if pieces[i].kind == .toolUse {
                    // Paired if the very next piece is its result.
                    let isPaired = (i + 1 < pieces.count && pieces[i + 1].kind == .toolResult)
                    id = pieces[i].id  // always track
                    if isPaired { i += 1 } // skip the result so it's consumed
                }
                i += 1
            }
            return id
        }()

        var calls: [UnifiedToolCallDisplay] = []
        var index = 0
        while index < pieces.count {
            let piece = pieces[index]
            switch piece.kind {
            case .toolUse:
                var resultText: String?
                if index + 1 < pieces.count, pieces[index + 1].kind == .toolResult {
                    let resultPiece = pieces[index + 1]
                    resultText = (resultPiece.detail?.isEmpty == false) ? resultPiece.detail : resultPiece.value
                    index += 1  // consume the paired result
                }
                calls.append(UnifiedToolCallDisplay(
                    id: piece.id,
                    name: piece.value,
                    detail: piece.detail,
                    result: resultText,
                    isRunning: isStreaming && piece.id == lastUnpairedToolUseID
                ))
            case .toolResult:
                // An unpaired result that survived after the pairing loop above
                // means the transcript ordering is unexpected (result without a
                // preceding toolUse in this group). Drop it silently to avoid
                // a ghost "result" row — the information is not lost because the
                // Mac transcript always emits toolUse before toolResult.
                break
            case .text, .reasoning, .refusal:
                break
            }
            index += 1
        }
        return calls
    }

    // MARK: - Transcript Grouping

    private var groupedTranscript: [TranscriptGroup] {
        TranscriptGroup.group(transcript)
    }

    @ViewBuilder
    private func proseBubble(isUser: Bool, text: String, appendCaret: Bool) -> some View {
        let alignment: HorizontalAlignment = isUser ? .trailing : .leading
        // Use atom-aware Hermes rendering for assistant turns even while the
        // stream is live; the caret is appended inside the rich text so we
        // don't snap from raw text to atoms at finalize.
        let useHermesRichRendering = !isUser && isHermes && !text.isEmpty

        if !text.isEmpty || appendCaret {
            let prose = proseBubbleBody(
                isUser: isUser,
                text: text,
                useHermesRichRendering: useHermesRichRendering,
                appendCaret: appendCaret,
                alignment: alignment
            )

            if isUser {
                prose
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm + 2)
                    .background {
                        ChatBubbleStyle.userShape().fill(ChatBubbleStyle.userFill(colorScheme))
                    }
            } else {
                // No container — but it still needs a bound. The bubble's
                // padding used to be what stopped the text reporting its full
                // unwrapped width; with the bubble gone, `fixedSize` is what
                // makes it wrap to the row instead of overflowing it, which is
                // why the narrow panels were clipping mid-sentence.
                prose
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, DesignSystem.Spacing.sm)
                    .padding(.vertical, 2)
            }
        }
    }

    /// Switch between native `Text` and atom-aware `HermesRichBubble`.
    /// Streaming and error rendering keep using `Text` so we never re-layout
    /// chips on every SSE chunk.
    @ViewBuilder
    private func proseBubbleBody(
        isUser: Bool,
        text: String,
        useHermesRichRendering: Bool,
        appendCaret: Bool,
        alignment: HorizontalAlignment
    ) -> some View {
        ChatLimitedProseTextView(
            text: text,
            appendCaret: appendCaret,
            useHermesRichRendering: useHermesRichRendering,
            alignment: alignment,
            isUser: isUser
        )
    }
}

// remediation(chat-streaming-o2): identity-stable, diffable transcript rows.
// The row carries an `onJumpToLocal` closure, which SwiftUI's
// reflection-based change detection can never prove equal — so every ~80ms
// streaming commit re-rendered EVERY row in the transcript, making each
// commit O(total transcript). This semantic equality (used via
// `.equatable()` in `ChatMessagesStream`) compares the render inputs and
// treats the closure by presence only: nil-ness is what gates the disabled
// chip state, and the closure body always routes to the same controller
// jump call.
// `nonisolated`: the Equatable witness must not inherit the struct's
// View-conformance MainActor isolation. Safe — both operands are value
// copies and SwiftUI performs the comparison during main-actor rendering.
extension ChatMessageView: Equatable {
    nonisolated static func == (lhs: ChatMessageView, rhs: ChatMessageView) -> Bool {
        lhs.message == rhs.message
            && lhs.isStreaming == rhs.isStreaming
            && lhs.showViaBadge == rhs.showViaBadge
            && lhs.isHermes == rhs.isHermes
            && lhs.assistantModelKey == rhs.assistantModelKey
            && lhs.viewMode == rhs.viewMode
            && lhs.memoryCitations == rhs.memoryCitations
            && (lhs.onJumpToLocal == nil) == (rhs.onJumpToLocal == nil)
    }
}

/// Reports the agent bubble row's available width up to `ChatMessageView`
/// so the opposite-side gutter can ease down on narrow panels.
private struct AgentRowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Oversized Chat Text Guard

struct ChatMessageTextPresentation: Equatable {
    let visibleText: String
    let hiddenCharacterCount: Int

    var isLimited: Bool { hiddenCharacterCount > 0 }
}

enum ChatMessageTextLimiter {
    static let defaultVisibleCharacterLimit = 4_000

    static func presentation(
        for text: String,
        expanded: Bool,
        visibleCharacterLimit: Int = defaultVisibleCharacterLimit
    ) -> ChatMessageTextPresentation {
        // `text.utf8.count` is O(1) and always ≥ `text.count`, so a text
        // whose UTF-8 length fits the limit can never exceed it in
        // characters — skip the O(n) grapheme walk for the common case.
        guard !expanded,
              visibleCharacterLimit > 0,
              text.utf8.count > visibleCharacterLimit,
              text.count > visibleCharacterLimit else {
            return ChatMessageTextPresentation(visibleText: text, hiddenCharacterCount: 0)
        }

        let end = text.index(text.startIndex, offsetBy: visibleCharacterLimit)
        return ChatMessageTextPresentation(
            visibleText: String(text[..<end]),
            hiddenCharacterCount: text.count - visibleCharacterLimit
        )
    }
}

private struct ChatLimitedProseTextView: View {
    let text: String
    let appendCaret: Bool
    let useHermesRichRendering: Bool
    let alignment: HorizontalAlignment
    let isUser: Bool

    @State private var isExpanded = false
    /// Incremental markdown renderer for the non-rich assistant path.
    /// Parses only the bytes that arrived since the previous streaming
    /// commit plus the trailing partial line, instead of re-parsing the
    /// entire accumulated reply per commit (O(n²) across a long stream).
    /// One renderer per prose piece identity (`@State`); it self-resets
    /// when the text shrinks or is replaced (e.g. collapse after stream).
    @State private var streamedMarkdownRenderer = HermesStreamingMarkdownRenderer()

    private var presentation: ChatMessageTextPresentation {
        ChatMessageTextLimiter.presentation(
            for: text,
            expanded: isExpanded || appendCaret
        )
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 8) {
            renderedText

            if presentation.isLimited {
                Button {
                    withAnimation(DesignSystem.Animation.gentle) {
                        isExpanded = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.down")
                            .font(DesignSystem.Typography.tiny)
                        Text("Show full message (\(presentation.hiddenCharacterCount.formatted()) more characters)")
                    }
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(isUser ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.hermesAureate)
                }
                .buttonStyle(.plain)
                .help("Render the full stored chat message")
            }
        }
    }

    @ViewBuilder
    private var renderedText: some View {
        if useHermesRichRendering {
            let display = presentation.visibleText + (appendCaret ? "▍" : "")
            StreamingBubble(
                text: display,
                isStreaming: appendCaret,
                isError: false,
                baseSize: 14,
                lineHeight: 20
            ) {
                HermesRichBubble(
                    text: display,
                    baseColor: DesignSystem.Colors.textPrimary,
                    mentionColor: DesignSystem.Colors.hermesAureate,
                    codeColor: DesignSystem.Colors.textPrimary,
                    codeBackground: DesignSystem.Colors.surfaceElevated,
                    isStreaming: appendCaret
                )
            }
        } else if isUser {
            // User turns stay verbatim (and never stream a caret).
            Text(AttributedString(presentation.visibleText + (appendCaret ? "▍" : "")))
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .textSelection(.enabled)
        } else {
            // Non-Hermes assistant turns (mirrored CLI agents, Pi, …) arrive
            // as markdown too — resolve inline emphasis instead of showing
            // raw `**` markers. The incremental renderer keeps the
            // per-commit parse cost O(delta + partial line) instead of
            // O(full accumulated text), and the caret rides as a suffix so
            // it never forces a full copy of the accumulated string. The
            // animation keys on the O(1) UTF-8 length instead of the O(n)
            // grapheme count — both grow monotonically per append.
            Text(
                streamedMarkdownRenderer.attributedString(
                    for: presentation.visibleText,
                    suffix: appendCaret ? "▍" : ""
                )
            )
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .textSelection(.enabled)
                .animation(.easeOut(duration: 0.12), value: presentation.visibleText.utf8.count)
        }
    }
}
