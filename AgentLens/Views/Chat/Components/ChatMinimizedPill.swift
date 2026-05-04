import SwiftUI

struct ChatMinimizedPill: View {
    @Bindable var controller: ChatSessionController
    var containerSize: CGSize
    var edgePadding: CGFloat
    var onExpand: () -> Void
    @State private var pillDragStart: CGSize?

    var body: some View {
        let modeColor: Color = controller.chatBackend == .hermes
            ? DesignSystem.Colors.hermesAureate
            : DesignSystem.Colors.whimsy
        let modeIcon = controller.chatBackend == .hermes ? "\u{263F}" : "bubble.left.and.bubble.right.fill"
        Button {
            onExpand()
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                if controller.chatBackend == .hermes {
                    Text(modeIcon).font(.system(size: 14, weight: .medium, design: .rounded)).foregroundStyle(modeColor)
                } else {
                    Image(systemName: modeIcon).font(.system(size: 12, weight: .medium)).foregroundStyle(modeColor)
                }
                if controller.isStreaming {
                    ProgressView().controlSize(.mini).tint(modeColor)
                } else if let last = controller.messages.last {
                    Text(last.role == .user ? last.content : ChatMessageRecord.joinedText(from: last.displayTranscript))
                        .font(DesignSystem.Typography.tiny).foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1).truncationMode(.tail).frame(maxWidth: 160)
                }
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 9, weight: .bold)).foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .padding(.horizontal, DesignSystem.Spacing.md).padding(.vertical, DesignSystem.Spacing.sm)
            .background {
                ZStack {
                    Capsule(style: .continuous).fill(.ultraThinMaterial)
                    Capsule(style: .continuous).fill(DesignSystem.Colors.surface.opacity(0.55))
                }
            }
            .clipShape(Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(LinearGradient(colors: [modeColor.opacity(0.5), DesignSystem.Colors.border.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75))
            .shadow(color: Color.black.opacity(0.15), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .highPriorityGesture(
            DragGesture(minimumDistance: 6)
                .onChanged { g in
                    if pillDragStart == nil { pillDragStart = controller.panelFloatOffset }
                    let start = pillDragStart ?? .zero
                    controller.applyClampedPanelDrag(start: start, translation: g.translation, container: containerSize, padding: edgePadding)
                }
                .onEnded { _ in
                    pillDragStart = nil
                    controller.persistPanelGeometry()
                }
        )
        .transition(.scale(scale: 0.6).combined(with: .opacity))
    }
}
