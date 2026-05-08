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

    private var transcript: [ChatTranscriptPiece] {
        message.displayTranscript
    }

    private var lastTextPieceId: String? {
        transcript.last { $0.kind == .text }?.id
    }

    var body: some View {
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

    /// Horizontally scrollable strip of tool cards, most recent on the left.
    @ViewBuilder
    private func toolGroupStrip(_ pieces: [ChatTranscriptPiece]) -> some View {
        let reversedPieces = Array(pieces.reversed())
        let lastToolID = transcript.last(where: { $0.kind == .toolUse })?.id
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                if isHermes {
                    ForEach(reversedPieces) { piece in
                        HermesToolCard(
                            toolName: piece.value,
                            detail: piece.detail,
                            isRunning: isStreaming && piece.id == lastToolID
                        )
                    }
                } else {
                    ForEach(reversedPieces) { piece in
                        toolUseSubBubble(piece)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.25))
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(toolGroupStripBorder, lineWidth: 0.5)
        )
    }

    private var toolGroupStripBorder: AnyShapeStyle {
        if isHermes {
            return AnyShapeStyle(DesignSystem.Colors.mercuryGradient.opacity(0.3))
        } else {
            return AnyShapeStyle(LinearGradient(
                colors: [DesignSystem.Colors.coral.opacity(0.2), DesignSystem.Colors.purple.opacity(0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
    }

    // MARK: - Transcript Grouping

    private var groupedTranscript: [TranscriptGroup] {
        TranscriptGroup.group(transcript)
    }

    @ViewBuilder
    private func toolUseSubBubble(_ piece: ChatTranscriptPiece) -> some View {
        let shape = ChatBubbleStyle.toolShape()
        VStack(alignment: .leading, spacing: 4) {
            Text(piece.value)
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.primaryGradient)

            if let detail = piece.detail, !detail.isEmpty {
                Text(detail)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(5)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            ZStack {
                shape
                    .fill(.ultraThinMaterial)
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.coral.opacity(0.10),
                                DesignSystem.Colors.purple.opacity(0.06),
                                Color.clear
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
                            DesignSystem.Colors.coral.opacity(0.85),
                            DesignSystem.Colors.purple.opacity(0.75)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: DesignSystem.Colors.purple.opacity(0.12), radius: 6, y: 2)
    }

    @ViewBuilder
    private func proseBubble(isUser: Bool, text: String, appendCaret: Bool) -> some View {
        let shape = isUser ? ChatBubbleStyle.userShape() : ChatBubbleStyle.assistantShape()
        let stroke = isUser ? ChatBubbleStyle.userStroke : (isHermes ? DesignSystem.Colors.hermesMercury : ChatBubbleStyle.assistantStroke)
        let alignment: HorizontalAlignment = isUser ? .trailing : .leading
        let display = text + (appendCaret ? "▍" : "")
        // Use atom-aware Hermes rendering for completed Hermes assistant turns;
        // fall back to plain `Text` for user messages, error states, and live
        // streaming chunks (atom layout would thrash on every chunk).
        let useHermesRichRendering = !isUser && isHermes && !appendCaret && !text.isEmpty

        if !display.isEmpty || appendCaret {
            proseBubbleBody(
                isUser: isUser,
                text: text,
                display: display,
                useHermesRichRendering: useHermesRichRendering,
                isStreaming: appendCaret,
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
        display: String,
        useHermesRichRendering: Bool,
        isStreaming: Bool,
        alignment: HorizontalAlignment
    ) -> some View {
        if useHermesRichRendering {
            StreamingBubble(
                text: text,
                isStreaming: false,
                isError: false,
                baseSize: 14,
                lineHeight: 20
            ) {
                HermesRichBubble(
                    text: text,
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
                .animation(.easeOut(duration: 0.12), value: text.count)
        }
    }
}
