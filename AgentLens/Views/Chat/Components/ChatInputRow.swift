import SwiftUI

struct ChatInputRow: View {
    @Bindable var controller: ChatSessionController
    var chatBackend: ChatBackendID
    var onSubmit: () -> Void

    private var inputPlaceholder: String {
        switch chatBackend {
        case .codex: return "Ask Codex\u{2026}"
        case .claude: return "Ask Claude Code\u{2026}"
        case .hermes: return "Ask Hermes\u{2026}"
        case .openclaw: return "Ask OpenClaw\u{2026}"
        }
    }

    private var inputStrokeGradient: LinearGradient {
        chatBackend == .hermes
            ? LinearGradient(colors: [DesignSystem.Colors.hermesMercury.opacity(0.4), DesignSystem.Colors.hermesAureate.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [DesignSystem.Colors.whimsy.opacity(0.3), DesignSystem.Colors.border.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.lastRetrievalHadNoEvidence, !controller.isStreaming {
                Text("No indexed excerpts matched your last question\u{2014}try \u{201c}Search indexed sessions\u{201d}, enable indexing in Settings, or rephrase.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .bottom, spacing: DesignSystem.Spacing.sm) {
                TextField(inputPlaceholder, text: $controller.inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.body)
                    .lineLimit(1...5)
                    .submitLabel(.send)
                    .onSubmit { onSubmit() }
                    .padding(DesignSystem.Spacing.sm)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous).fill(.ultraThinMaterial)
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.3))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous).strokeBorder(inputStrokeGradient, lineWidth: 0.75))
                    .animation(DesignSystem.Animation.snappy, value: chatBackend)

                VStack(spacing: 6) {
                    if controller.isStreaming {
                        Button("Stop") { controller.cancelGeneration() }
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.error)
                    }
                    Button {
                        onSubmit()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(chatBackend == .hermes ? AnyShapeStyle(DesignSystem.Colors.mercuryGradient) : AnyShapeStyle(DesignSystem.Colors.primaryGradient))
                    }
                    .buttonStyle(.plain)
                    .disabled(controller.isStreaming || controller.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
    }
}
