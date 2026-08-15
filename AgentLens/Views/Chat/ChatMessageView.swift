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
    /// Approve/dismiss callbacks for a proposal card (M4). Keyed by message id.
    var onApproveProposal: ((String) -> Void)?
    var onDismissProposal: ((String) -> Void)?

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

            if message.cancelled {
                Text("Generation cancelled")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.warning.opacity(0.08))
                    )
            }

            if let proposal = message.proposalJSON {
                proposalCard(proposalJSON: proposal)
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

    // MARK: - Proposal card (M4)

    /// Renders a directive proposal with explicit approve/dismiss actions
    /// (VAL-ORCH-011). A decided proposal shows its outcome and has no second
    /// approve action (VAL-ORCH-012/013).
    @ViewBuilder
    private func proposalCard(proposalJSON: String) -> some View {
        let proposal = BurnBarFleetProposalWire.decode(json: proposalJSON)
        let decision = message.proposalDecision

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.whimsy)
                Text("Directive proposal")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            if let proposal {
                Text("\(proposal.kind.rawValue) · \(proposal.targetAgent?.wireValue ?? "any")")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text(proposal.payload)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("id: \(proposal.id)")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            } else {
                Text("Malformed proposal payload")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.error)
            }

            if let decision {
                let isApproved = decision == .approved
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: isApproved ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isApproved ? DesignSystem.Colors.success : DesignSystem.Colors.error)
                    Text(isApproved ? "Approved" : "Dismissed")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(isApproved ? DesignSystem.Colors.success : DesignSystem.Colors.error)
                }
            } else if let onApproveProposal, let onDismissProposal {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button("Approve") {
                        onApproveProposal(message.id)
                    }
                    .font(DesignSystem.Typography.caption)
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.success)

                    Button("Dismiss") {
                        onDismissProposal(message.id)
                    }
                    .font(DesignSystem.Typography.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: 300, alignment: .leading)
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            DesignSystem.Colors.whimsy.opacity(0.5),
                            DesignSystem.Colors.border.opacity(0.3)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Directive proposal")
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
