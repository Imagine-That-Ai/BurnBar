import SwiftUI

// MARK: - Hermes Popover Strip

/// Compact Hermes chat input in the menu bar popover.
/// Shows a single-line input with mercury border, plus a tappable last-message preview
/// when a conversation exists. Sending a message or tapping the preview collapses the
/// entire popover into the full `HermesPopoverChatView`.
struct HermesPopoverStrip: View {
    @Bindable var controller: ChatSessionController
    var onOpenDashboardWithChat: () -> Void
    var onActivateChat: (() -> Void)?
    var hermesSetupCompleted: Bool = true
    var onRequireHermesSetup: (() -> Void)?

    @State private var isHovered = false

    private var stripPlaceholder: String {
        switch controller.chatBackend {
        case .codex: return "Ask Codex…"
        case .claude: return "Ask Claude…"
        case .hermes: return "Ask Hermes…"
        case .openclaw: return "Ask OpenClaw…"
        case .piAgent: return "Ask Pi…"
        }
    }

    private var hasConversation: Bool {
        !stripThreadMessages.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            collapsedRow

            if hasConversation {
                lastMessagePreview
            }
        }
        .background(DesignSystem.Colors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay {
            mercuryBorder
        }
        .onHover { isHovered = $0 }
        .animation(DesignSystem.Animation.gentle, value: hasConversation)
        .animation(DesignSystem.Animation.gentle, value: controller.messages.count)
    }

    // MARK: - Collapsed Row

    private var collapsedRow: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text("\u{263F}")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.hermesAureate)

            TextField(stripPlaceholder, text: $controller.inputText)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .popoverTooltip("Chat with your AI assistant")
                .onSubmit {
                    sendAndExpand()
                }

            if !controller.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    sendAndExpand()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            if controller.isStreaming {
                Button {
                    controller.cancelGeneration()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(DesignSystem.Colors.error)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, DesignSystem.Spacing.md)
    }

    // MARK: - Thread Preview

    private var stripThreadMessages: [ChatMessageRecord] {
        controller.messages
    }

    /// Tappable single-line preview of the last message. Tapping collapses the popover into full chat.
    private var lastMessagePreview: some View {
        Button {
            onActivateChat?()
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                if let last = stripThreadMessages.last {
                    let icon = last.role == .user ? "person.fill" : "sparkles"
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.hermesMercury)
                    Text(last.content)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs + 2)
            .background(DesignSystem.Colors.hermesMercury.opacity(0.04))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mercury Border

    private var mercuryBorder: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isHovered && !controller.isStreaming)) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 3.0) / 3.0

            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(
                    mercuryAnimatedGradient(phase: CGFloat(phase)),
                    lineWidth: 1
                )
        }
        .allowsHitTesting(false)
    }

    private func mercuryAnimatedGradient(phase: CGFloat) -> LinearGradient {
        let p = phase
        let w: CGFloat = 0.2

        return LinearGradient(
            stops: [
                .init(color: DesignSystem.Colors.hermesMercury.opacity(0.5), location: 0),
                .init(color: DesignSystem.Colors.hermesMercury, location: max(0, p - w)),
                .init(color: .white.opacity(0.7), location: p),
                .init(color: DesignSystem.Colors.hermesAureate, location: min(1, p + w)),
                .init(color: DesignSystem.Colors.hermesAureate.opacity(0.4), location: 1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Actions

    private func sendAndExpand() {
        if controller.chatBackend == .hermes && !hermesSetupCompleted {
            onRequireHermesSetup?()
            return
        }
        // Transition immediately so the user sees the full chat view.
        onActivateChat?()
        // Fire send on the controller — NOT tied to this view's task lifecycle.
        // This way the send survives the strip being removed from the hierarchy.
        controller.fireAndForgetSend()
    }
}
