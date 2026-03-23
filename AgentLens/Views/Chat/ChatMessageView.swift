import SwiftUI

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
                assistantTranscriptColumn
                Spacer(minLength: 36)
            }
        }
    }

    private var userProse: String {
        transcript.filter { $0.kind == .text }.map(\.value).joined()
    }

    private var userProseBubble: some View {
        proseBubble(
            isUser: true,
            text: userProse.isEmpty ? message.content : userProse,
            appendCaret: false
        )
    }

    private var assistantTranscriptColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showViaBadge, let via = message.cliUsed {
                Text("via \(via)")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            ForEach(transcript) { piece in
                switch piece.kind {
                case .toolUse:
                    toolUseSubBubble(piece)
                case .text:
                    proseBubble(
                        isUser: false,
                        text: piece.value,
                        appendCaret: isStreaming && piece.id == lastTextPieceId
                    )
                }
            }
        }
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
        let stroke = isUser ? ChatBubbleStyle.userStroke : ChatBubbleStyle.assistantStroke
        let alignment: HorizontalAlignment = isUser ? .trailing : .leading
        let display = text + (appendCaret ? "▍" : "")

        if !display.isEmpty || appendCaret {
            Text(display)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .textSelection(.enabled)
                .animation(.easeOut(duration: 0.12), value: text.count)
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
}
