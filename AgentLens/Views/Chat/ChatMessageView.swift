import SwiftUI
import OpenBurnBarCore

// MARK: - Chat Message View

private enum ChatBubbleStyle {
    static let userStroke = DesignSystem.Colors.chatUserStroke
    static let assistantStroke = DesignSystem.Colors.chatAssistantStroke

    static func userShape() -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 22,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 7,
            topTrailingRadius: 18,
            style: .continuous
        )
    }

    static func assistantShape() -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 8,
            bottomLeadingRadius: 20,
            bottomTrailingRadius: 22,
            topTrailingRadius: 20,
            style: .continuous
        )
    }

    static func toolShape() -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 10,
            bottomLeadingRadius: 8,
            bottomTrailingRadius: 12,
            topTrailingRadius: 6,
            style: .continuous
        )
    }
}

struct ChatMessageView: View {
    let message: ChatMessageRecord
    var isStreaming: Bool
    var showViaBadge: Bool
    var isHermes: Bool = false
    /// When set (e.g. Hermes `/v1/models`), shows vendor logo beside assistant turns.
    var assistantModelKey: String? = nil
    /// Display mode: rich agent bubbles or raw CLI output.
    var viewMode: ChatViewMode = .agent

    private var transcript: [ChatTranscriptPiece] {
        message.displayTranscript
    }

    private var lastTextPieceId: String? {
        transcript.last { $0.kind == .text }?.id
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
        HStack(alignment: .bottom, spacing: DesignSystem.Spacing.sm) {
            if message.role == .user {
                Spacer(minLength: 36)
                userProseBubble
            } else {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                    if let raw = assistantModelKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                        ModelProviderLogoView(
                            modelKey: raw,
                            size: 24,
                            fallbackSymbolColor: isHermes ? DesignSystem.Colors.hermesMercury : nil
                        )
                        .padding(.top, 2)
                    }
                    assistantTranscriptColumn
                }
                Spacer(minLength: 36)
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
                        proseBubble(
                            isUser: false,
                            text: piece.value,
                            appendCaret: isStreaming && piece.id == lastTextPieceId
                        )
                    }
                }
            }
        }
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
            var id: String? = nil
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
            case .text:
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
        let shape = isUser ? ChatBubbleStyle.userShape() : ChatBubbleStyle.assistantShape()
        let stroke = isUser ? ChatBubbleStyle.userStroke : (isHermes ? DesignSystem.Colors.hermesMercury : ChatBubbleStyle.assistantStroke)
        let alignment: HorizontalAlignment = isUser ? .trailing : .leading
        // Use atom-aware Hermes rendering for assistant turns even while the
        // stream is live; the caret is appended inside the rich text so we
        // don't snap from raw text to atoms at finalize.
        let useHermesRichRendering = !isUser && isHermes && !text.isEmpty

        if !text.isEmpty || appendCaret {
            proseBubbleBody(
                isUser: isUser,
                text: text,
                useHermesRichRendering: useHermesRichRendering,
                appendCaret: appendCaret,
                alignment: alignment
            )
                .padding(.horizontal, DesignSystem.Spacing.md + 2)
                .padding(.vertical, DesignSystem.Spacing.md)
                .background {
                    ZStack {
                        shape
                            .fill(.ultraThinMaterial)
                        shape
                            .fill(DesignSystem.Colors.surface.opacity(0.35))
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        stroke.opacity(isUser ? 0.10 : 0.12),
                                        Color.white.opacity(0.03),
                                        stroke.opacity(0.03)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
                .overlay(
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    stroke.opacity(0.7),
                                    Color.white.opacity(0.1),
                                    stroke.opacity(0.4)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: stroke.opacity(0.12), radius: 10, y: 4)
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

// MARK: - Oversized Chat Text Guard

struct ChatMessageTextPresentation: Equatable {
    let visibleText: String
    let hiddenCharacterCount: Int

    var isLimited: Bool { hiddenCharacterCount > 0 }
}

enum ChatMessageTextLimiter {
    static let defaultVisibleCharacterLimit = 12_000

    static func presentation(
        for text: String,
        expanded: Bool,
        visibleCharacterLimit: Int = defaultVisibleCharacterLimit
    ) -> ChatMessageTextPresentation {
        guard !expanded, visibleCharacterLimit > 0, text.count > visibleCharacterLimit else {
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
                    isExpanded = true
                } label: {
                    Text("Show full message (\(presentation.hiddenCharacterCount.formatted()) more characters)")
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
        let display = presentation.visibleText + (appendCaret ? "▍" : "")
        if useHermesRichRendering {
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
                    codeBackground: DesignSystem.Colors.surfaceElevated
                )
            }
        } else {
            Text(display)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .textSelection(.enabled)
                .animation(.easeOut(duration: 0.12), value: display.count)
        }
    }
}
