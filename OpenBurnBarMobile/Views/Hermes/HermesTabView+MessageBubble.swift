import SwiftUI
import AVFoundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// Chat message bubble.
// Extracted from HermesTabView.swift (god-file decomposition) — same module, verbatim.

struct HermesMessageBubble: View {
    let message: HermesChatMessage
    /// The per-surface service this bubble renders inside. Used to resolve
    /// the surface's selected thread for the system-permission pill —
    /// `HermesService.shared` carries no conversation state, so reading
    /// `selectedSessionID` off it always came back nil and the pill never
    /// rendered.
    let hermesService: HermesService
    var showTPS: Bool = false
    /// When true, assistant text is rendered through `HermesRichBubble` so
    /// markdown emphasis renders styled and `@mentions` / `` `code spans` ``
    /// get inline chips with pretext line breaking. Falls back to native
    /// `Text` if the engine isn't ready. When false, inline markdown still
    /// resolves through an attributed `Text` — only chips and engine layout
    /// are skipped.
    var usePretextRendering: Bool = true
    /// Display mode: rich agent bubbles or raw CLI output.
    var viewMode: ChatViewMode = .agent
    /// Optional retry callback. The container passes a non-nil value
    /// only for the most recent assistant turn whose outcome supports
    /// retry — the bubble renders the inline "Try again" pill in that
    /// case. Earlier turns and successful replies pass nil (no pill).
    var onRetry: (() -> Void)?

    @State private var permissionSheetItem: SystemPermissionItem?
    @State private var permissionStore = SystemPermissionInboxStore.shared

    var isUser: Bool { message.role == .user }

    @ViewBuilder
    fileprivate var systemPermissionPillIfNeeded: some View {
        let threadID = hermesService.selectedSessionID ?? ""
        if !threadID.isEmpty,
           let item = permissionStore.latestItem(forThread: threadID),
           item.originatingToolCallId == message.id
            || message.toolCalls.contains(where: { $0.id == item.originatingToolCallId }) {
            SystemPermissionInlinePill(item: item) {
                permissionSheetItem = item
            }
            .padding(.leading, 6)
            .padding(.top, 4)
            .sheet(item: $permissionSheetItem) { sheetItem in
                if let sender = makeSystemPermissionGrantSender() {
                    SystemPermissionGrantSheet(item: sheetItem, sender: sender)
                } else {
                    SystemPermissionGrantSheet(
                        item: sheetItem,
                        sender: SystemPermissionGrantSender(senderFactory: { nil })
                    )
                }
            }
        }
    }

    private func makeSystemPermissionGrantSender() -> SystemPermissionGrantSender? {
        // Resolve via the live AgentWatchOverlaySingleton so the sender
        // shares the same Computer Use control stream + signing key that
        // every other phone-control surface uses.
        let factory: SystemPermissionGrantSender.SenderFactory = {
            AgentWatchOverlaySingleton.shared.activePhoneControlSender()
        }
        return SystemPermissionGrantSender(senderFactory: factory)
    }

    var body: some View {
        if viewMode == .cli {
            iosCLIMessageRow
        } else {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.attachments.isEmpty {
                        ChatBubbleAttachmentStrip(attachments: message.attachments)
                            .frame(maxWidth: 270)
                    }
                    if !message.text.isEmpty {
                        userBubble
                    }
                }
            } else {
                assistantStack
                Spacer(minLength: 48)
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
        .onAppear { refreshSourceLinks() }
        .onChange(of: message.isStreaming) { _, streaming in
            if !streaming { refreshSourceLinks() }
        }
        }
    }

    // MARK: - CLI View

    @ViewBuilder
    private var iosCLIMessageRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isUser {
                HStack(alignment: .top, spacing: 4) {
                    Text(">")
                        .font(MobileTheme.Typography.mono)
                        .foregroundStyle(MobileTheme.Colors.success)
                        .frame(width: 14, alignment: .trailing)
                    Text(message.text)
                        .font(MobileTheme.Typography.monoSmall)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: 4) {
                    Text("☿")
                        .font(MobileTheme.Typography.mono)
                        .foregroundStyle(MobileTheme.hermesAureate)
                        .frame(width: 14, alignment: .trailing)
                    Text(iosCLITranscriptText)
                        .font(MobileTheme.Typography.monoSmall)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private var iosCLITranscriptText: String {
        let toolLines = message.toolCalls.map { tc in
            "⟨\(tc.name)\(tc.detail != nil ? ": \(tc.detail!)" : "")⟩"
        }
        if toolLines.isEmpty { return message.text }
        return ([message.text] + toolLines).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var userBubble: some View {
        Text(message.text)
            .font(MobileTheme.Typography.body)
            .foregroundStyle(MobileTheme.Colors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                userBubbleShape
                    .fill(MobileTheme.Colors.surfaceElevated)
            )
    }

    @ViewBuilder
    private var assistantStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            modelBadge

            if message.outcome != .normal {
                outcomeBadge
                    .padding(.leading, 6)
                    .padding(.bottom, 2)
            }

            if !message.text.isEmpty || message.toolCalls.isEmpty {
                if rendersPlainAssistantBody {
                    // ChatGPT-style: normal assistant turns are plain text on
                    // the backdrop — no bubble chrome, no shimmer sweep. The
                    // old per-bubble repeat-forever shimmer also fought the
                    // swarm canvas for the main-thread frame budget, which
                    // read as visible jank while the swarm formed shapes.
                    assistantTextBody
                        .padding(.vertical, 2)
                        // Soften the one-frame re-measure when the cheap
                        // streaming renderer hands off to the rich bubble.
                        .animation(.easeInOut(duration: 0.18), value: message.isStreaming)
                } else {
                    // Non-normal outcomes (errors, refusals, length caps…)
                    // keep a tinted container so they read as different.
                    assistantTextBody
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(assistantBubbleShape.fill(bubbleFill))
                        .overlay(assistantBubbleShape.stroke(bubbleStroke, lineWidth: bubbleStrokeWidth))
                        .animation(.easeInOut(duration: 0.18), value: message.isStreaming)
                }
            }

            if let onRetry, message.outcome.supportsRetry {
                retryPill(onRetry: onRetry)
                    .padding(.leading, 6)
                    .padding(.top, 2)
            }

            if !message.toolCalls.isEmpty {
                UnifiedToolCallAccordion(calls: unifiedToolCalls, accent: .hermes)
            }

            if !message.attachments.isEmpty {
                ChatBubbleAttachmentStrip(attachments: message.attachments)
                    .frame(maxWidth: 270, alignment: .leading)
                    .padding(.leading, 6)
                    .padding(.top, 2)
            }

            systemPermissionPillIfNeeded

            // Hermes Square §6.6 — typed UI cards the agent emitted on
            // this turn render inline above the tpsFooter. Host-drawn:
            // the agent never touches our view tree; the envelope decoder
            // enforces the 2 MB per-card budget.
            if !message.cards.isEmpty {
                cardsStrip
            }

            if !sourceLinks.isEmpty {
                sourceLinksFooter
                    .padding(.leading, 6)
                    .padding(.top, 4)
            }

            tpsFooter
        }
    }

    private var cardsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.cards) { envelope in
                CardEnvelopeView(envelope: envelope, agentAccent: DesignSystemColors.ember)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Tool Calls

    /// Maps this turn's Hermes tool calls into the shared display model. The
    /// most recent call (last in the array) becomes the collapsed row; the
    /// live call pulses while the turn is still streaming.
    private var unifiedToolCalls: [UnifiedToolCallDisplay] {
        let lastID = message.toolCalls.last?.id
        return message.toolCalls.map { tc in
            UnifiedToolCallDisplay(
                id: tc.id,
                name: tc.name,
                statusRaw: tc.status,
                detail: tc.detail,
                arguments: tc.arguments,
                isRunning: message.isStreaming && tc.id == lastID
            )
        }
    }

    /// Honest "via Hermes" header. Renders one of three states:
    /// - `via Hermes · gpt-5.5` — server confirmed model (no asterisk needed).
    /// - `via Hermes · asked gpt-5.5 → got minimax-m2.7` — server routed to a
    ///   different model than the user requested.
    /// - `via Hermes · gpt-5.5 (requested)` — server never confirmed which
    ///   model it ran. We say "requested" so the user knows we're echoing
    ///   their pick rather than asserting a fact.
    @ViewBuilder
    private var modelBadge: some View {
        HStack(spacing: 5) {
            HermesLiveGlyph(size: 16, isLive: message.isStreaming)
            Text(modelBadgeText)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(modelBadgeAccessibilityLabel)
    }

    private var modelBadgeText: String {
        let requested = message.requestedModelID?.nilIfBlank.map(FriendlyModelName.format)
        let response = message.responseModelID?.nilIfBlank.map(FriendlyModelName.format)

        if message.serverRoutedToDifferentModel,
           let requested,
           let response {
            return "via Hermes · asked \(requested) → got \(response)"
        }
        if let response {
            return "via Hermes · \(response)"
        }
        if let requested {
            return "via Hermes · \(requested) (requested)"
        }
        if let fallback = message.modelName?.nilIfBlank {
            return "via Hermes · \(FriendlyModelName.format(fallback)) (requested)"
        }
        return "via Hermes"
    }

    private var modelBadgeAccessibilityLabel: String {
        if message.serverRoutedToDifferentModel,
           let requested = message.requestedModelID?.nilIfBlank.map(FriendlyModelName.format),
           let response = message.responseModelID?.nilIfBlank.map(FriendlyModelName.format) {
            return "Hermes routed: requested \(requested), server ran \(response)."
        }
        if let response = message.responseModelID?.nilIfBlank.map(FriendlyModelName.format) {
            return "Hermes ran model \(response)."
        }
        if let requested = message.requestedModelID?.nilIfBlank.map(FriendlyModelName.format) {
            return "Hermes was requested \(requested). Server did not confirm the model."
        }
        return "Hermes assistant message."
    }

    @ViewBuilder
    private var tpsFooter: some View {
        if shouldRenderTPS, let display = message.tokensPerSecondDisplayText {
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .bold))
                Text(display)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                if message.isTokensPerSecondEstimated {
                    Text("est.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
            .foregroundStyle(MobileTheme.Colors.textSecondary)
            .padding(.leading, 6)
            .padding(.top, 2)
            .frame(minHeight: 16, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tpsAccessibilityLabel(display))
        } else if shouldRenderBufferedNotice {
            // Stream was buffered by a relay/proxy so wall-clock would lie.
            // Tell the user we're hiding the rate instead of fabricating one.
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .bold))
                Text("rate hidden — buffered stream")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(MobileTheme.Colors.textMuted)
            .padding(.leading, 6)
            .padding(.top, 2)
            .frame(minHeight: 16, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Generation rate hidden because the stream was buffered.")
        }
    }

    private var shouldRenderTPS: Bool {
        showTPS && !isUser && !message.isError
    }

    /// Surface the buffered notice only when (a) the user opted into TPS,
    /// (b) the server gave us a token count and (c) we deliberately suppressed
    /// the rate because the wall-clock was implausibly short.
    private var shouldRenderBufferedNotice: Bool {
        showTPS
            && !isUser
            && !message.isError
            && message.tokensPerSecond == nil
            && message.outputTokenCount.map { $0 > 0 } ?? false
            && message.generationDurationSource == .bufferedWallClock
    }

    /// Cached source-link extraction. The regex walk over the full message
    /// text is too expensive to re-run on every body evaluation, so we
    /// extract once when the bubble appears and again when streaming
    /// completes; history bubbles (never streamed) keep the onAppear result.
    @State private var sourceLinks: [HermesSourceLink] = []

    private func refreshSourceLinks() {
        guard !isUser, !message.text.isEmpty, !message.isStreaming else {
            sourceLinks = []
            return
        }
        sourceLinks = HermesSourceLinkExtractor.extract(from: message.text)
    }

    private var sourceLinksFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .bold))
                Text("Sources")
                    .font(MobileTheme.Typography.tiny.weight(.semibold))
            }
            .foregroundStyle(MobileTheme.Colors.textMuted)

            ForEach(sourceLinks) { source in
                Link(destination: source.url) {
                    HStack(spacing: 7) {
                        Image(systemName: "safari")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MobileTheme.hermesAureate)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.title)
                                .font(MobileTheme.Typography.caption.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(source.displayHost)
                                .font(MobileTheme.Typography.tiny)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(MobileTheme.Colors.surfaceElevated.opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(MobileTheme.Colors.border.opacity(0.28), lineWidth: 0.7)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open source: \(source.title)")
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.68))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.24), lineWidth: 0.7)
        )
    }

    private func tpsAccessibilityLabel(_ display: String) -> String {
        let prefix: String
        switch message.generationDurationSource {
        case .providerEvalDuration: prefix = ""
        case .wallClock:            prefix = "Estimated "
        case .bufferedWallClock:    prefix = "Estimated "
        case nil:                   prefix = "Estimated "
        }
        return "\(prefix)Generation speed \(display)"
    }

    /// Routes to either pretext rich rendering or plain native `Text` based on
    /// the user's preference and whether the message is in an error state.
    /// Error messages use plain Text because the contract is "render exactly
    /// what the server returned"; streaming text uses the cheap attributed
    /// fallback (rich layout re-measures the bubble on every chunk) and the
    /// atom-aware renderer takes over once the stream completes.
    @ViewBuilder
    private var assistantTextBody: some View {
        if usePretextRendering, !message.isError, !message.isStreaming {
            HermesRichBubble(
                text: HermesSourceLinkExtractor.collapseExternalLinksForDisplay(
                    in: message.text
                ),
                baseColor: MobileTheme.Colors.textPrimary,
                mentionColor: MobileTheme.hermesAureate,
                codeColor: MobileTheme.Colors.textPrimary,
                codeBackground: MobileTheme.Colors.surfaceElevated,
                lineHeight: 21
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Errors render exactly what the server returned. Non-error text
            // with Pretext off still resolves markdown emphasis — opting out
            // of chips and engine layout is not opting into raw `**` markers.
            Text(
                message.isError
                    ? AttributedString(message.text)
                    : HermesInlineMarkdown.attributedString(
                        message.text + (message.isStreaming ? "▍" : "")
                    )
            )
                .font(MobileTheme.Typography.body)
                .foregroundStyle(message.isError ? MobileTheme.Colors.error : MobileTheme.Colors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Normal (non-error, non-flagged) assistant turns render as plain text
    /// on the backdrop; containers are reserved for outcomes that need to
    /// read differently (errors, refusals, length caps…).
    private var rendersPlainAssistantBody: Bool {
        !message.isError && message.outcome == .normal
    }

    /// Bubble background tint, keyed off `outcome`. Refusals and the
    /// reasoning-channel fallback get a soft tinted background so the
    /// user sees they're not reading a normal answer; hard errors get
    /// a faint red wash; everything else uses the standard surface.
    private var bubbleFill: AnyShapeStyle {
        switch message.outcome {
        case .normal:
            if message.isError {
                return AnyShapeStyle(MobileTheme.error.opacity(0.06))
            }
            return AnyShapeStyle(MobileTheme.Colors.surface.opacity(0.85))
        case .refusal, .reasoningFallback:
            return AnyShapeStyle(MobileTheme.hermesAureate.opacity(0.07))
        case .lengthCap, .contentFilter, .toolCallNoFollowUp, .empty:
            return AnyShapeStyle(MobileTheme.error.opacity(0.06))
        }
    }

    private var bubbleStroke: AnyShapeStyle {
        if message.isError {
            return AnyShapeStyle(MobileTheme.error)
        }
        switch message.outcome {
        case .normal:
            return AnyShapeStyle(AuroraDesign.Gradients.mercuryFoil)
        case .refusal, .reasoningFallback:
            return AnyShapeStyle(MobileTheme.hermesAureate.opacity(0.55))
        case .lengthCap, .contentFilter, .toolCallNoFollowUp, .empty:
            return AnyShapeStyle(MobileTheme.error)
        }
    }

    private var bubbleStrokeWidth: CGFloat {
        message.isError ? 1.5 : 1
    }

    /// Inline tag rendered above the bubble for non-`.normal`
    /// outcomes. Symbol + label so power users can tell at a glance
    /// why the model didn't produce a normal reply. Returns `nil`
    /// for `.normal` so the call site can skip rendering entirely.
    @ViewBuilder
    private var outcomeBadge: some View {
        if let label = message.outcome.badgeLabel,
           let symbol = message.outcome.badgeSymbol {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                Text(label)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(outcomeBadgeColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(outcomeBadgeColor.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(outcomeBadgeColor.opacity(0.45), lineWidth: 0.5)
            )
            .accessibilityLabel(Text("Reply outcome: \(label)"))
        }
    }

    private var outcomeBadgeColor: Color {
        switch message.outcome {
        case .normal: return MobileTheme.Colors.textSecondary
        case .refusal, .reasoningFallback: return MobileTheme.hermesAureate
        case .lengthCap, .contentFilter, .toolCallNoFollowUp, .empty: return MobileTheme.error
        }
    }

    /// Inline retry pill rendered for the most recent assistant turn
    /// when its outcome supports retry. Tactile (haptic on tap),
    /// styled to match the bubble context — soft for soft outcomes,
    /// red for hard errors.
    @ViewBuilder
    private func retryPill(onRetry: @escaping () -> Void) -> some View {
        Button {
            HapticBus.send()
            onRetry()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .bold))
                Text("Try again")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(outcomeBadgeColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(outcomeBadgeColor.opacity(0.10))
            )
            .overlay(
                Capsule()
                    .stroke(outcomeBadgeColor.opacity(0.55), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Try again")
        .accessibilityHint("Re-sends your last message to Hermes.")
    }

    private var userBubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }

    private var assistantBubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }
}
