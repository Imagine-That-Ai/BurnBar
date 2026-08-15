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
    /// Retry callback for a failed/unsupported delivery (M4, VAL-ORCH-030/037).
    var onRetryDelivery: ((String) -> Void)?
    /// Reconciles an uncertain delivery with daemon state before another
    /// gateway attempt can be offered.
    var onReconcileDelivery: ((String) -> Void)?

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
            proposalHeader
            proposalBody(proposal: proposal)
            proposalErrorRow
            proposalActions(proposal: proposal, decision: decision)
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

    /// The card's header row (icon + "Directive proposal").
    private var proposalHeader: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11))
                .foregroundStyle(DesignSystem.Colors.whimsy)
            Text("Directive proposal")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
    }

    /// The card's payload rows: the decoded proposal, or a visibly
    /// non-actionable malformed state (scrutiny round 1) — no live-looking
    /// approve/dismiss buttons that would silently no-op.
    @ViewBuilder
    private func proposalBody(proposal: BurnBarFleetProposalWire?) -> some View {
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
            Text("Malformed proposal payload — no actions available")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.error)
            Text("This proposal could not be decoded. It will not be recorded or delivered.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The visible card-level typed error (scrutiny round 1): a daemon
    /// failure during Approve/Dismiss, or a critical local persistence
    /// failure, renders on the card itself — never only in streamError,
    /// which ChatPanel does not display. The pending proposal is preserved
    /// so the action stays retryable.
    @ViewBuilder
    private var proposalErrorRow: some View {
        if let proposalError = message.proposalError, !proposalError.isEmpty {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.error)
                    .padding(.top, 1)
                Text(proposalError)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(DesignSystem.Colors.error.opacity(0.08))
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Proposal error: \(proposalError)")

            if message.deliveryRecoveryRequired, message.deliveryState == nil,
               message.proposalDecision == .approved,
               let onReconcileDelivery {
                Button("Reconcile with daemon") {
                    onReconcileDelivery(message.id)
                }
                .font(DesignSystem.Typography.tiny)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.whimsy)
                .accessibilityLabel("Reconcile delivery with BurnBar daemon")
            }
        }
    }

    /// The card's consent/outcome row: the decided outcome (with delivery
    /// state), or approve/dismiss controls — only for a DECODED proposal
    /// (a malformed payload renders non-actionable above).
    @ViewBuilder
    private func proposalActions(
        proposal: BurnBarFleetProposalWire?,
        decision: ChatProposalDecision?
    ) -> some View {
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

            if isApproved, let deliveryState = message.deliveryState {
                deliveryStateRow(deliveryState)
            }
        } else if proposal != nil, let onApproveProposal, let onDismissProposal {
            // Only a DECODED proposal offers live consent controls: a
            // malformed persisted payload renders visibly non-actionable
            // above (scrutiny round 1).
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button(message.proposalError == nil ? "Approve" : "Retry approval") {
                    onApproveProposal(message.id)
                }
                .font(DesignSystem.Typography.caption)
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.success)
                .accessibilityLabel(message.proposalError == nil ? "Approve proposal" : "Retry proposal approval")

                Button("Dismiss") {
                    onDismissProposal(message.id)
                }
                .font(DesignSystem.Typography.caption)
                .buttonStyle(.bordered)
            }
        }
    }

    /// Renders the typed delivery state of an approved proposal (M4,
    /// VAL-ORCH-014/030/037): `delivering` while in flight, `delivered` on
    /// success, and typed `failed(reason)` / `unsupported(reason)` rows with
    /// a copy affordance and a single user-action retry — never a silent
    /// background loop.
    @ViewBuilder
    private func deliveryStateRow(_ state: ChatDeliveryState) -> some View {
        switch state {
        case .delivering:
            HStack(spacing: DesignSystem.Spacing.xs) {
                ProgressView()
                    .controlSize(.mini)
                Text("Delivering…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Delivering directive")
        case .delivered:
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.success)
                Text("Delivered")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.success)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Directive delivered")
        case .failed(let reason):
            deliveryIssueRow(
                icon: "exclamationmark.triangle.fill",
                color: DesignSystem.Colors.error,
                title: "Delivery failed",
                reason: reason
            )
        case .unsupported(let reason):
            deliveryIssueRow(
                icon: "hand.raised.slash.fill",
                color: DesignSystem.Colors.warning,
                title: "Delivery unsupported",
                reason: reason
            )
        }
    }

    @ViewBuilder
    private func deliveryIssueRow(
        icon: String,
        color: Color,
        title: String,
        reason: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(color)
            }

            Text(reason)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reason, forType: .string)
                }
                .font(DesignSystem.Typography.tiny)
                .buttonStyle(.bordered)

                if message.deliveryRecoveryRequired, let onReconcileDelivery {
                    Button("Reconcile") {
                        onReconcileDelivery(message.id)
                    }
                    .font(DesignSystem.Typography.tiny)
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.whimsy)
                } else if let onRetryDelivery {
                    Button("Retry") {
                        onRetryDelivery(message.id)
                    }
                    .font(DesignSystem.Typography.tiny)
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.whimsy)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title): \(reason)")
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
