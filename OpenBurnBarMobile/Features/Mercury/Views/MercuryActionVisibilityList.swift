import SwiftUI

/// Drag-to-reorder + toggle visibility for the three Mercury quick
/// actions. Hidden actions move below a "Hidden" divider so the user
/// can see what's available even after hiding it.
struct MercuryActionVisibilityList: View {
    @Binding var order: [MercuryQuickAction]
    let accent: Color
    let haptics: MercuryHapticsLevel

    private var hidden: [MercuryQuickAction] {
        MercuryQuickAction.allCases.filter { !order.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 8) {
                ForEach(order) { action in
                    row(for: action, isHidden: false)
                }
            }

            if !hidden.isEmpty {
                HStack {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 11))
                    Text("Hidden")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.white.opacity(0.45))
                .padding(.top, 6)

                VStack(spacing: 8) {
                    ForEach(hidden) { action in
                        row(for: action, isHidden: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for action: MercuryQuickAction, isHidden: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isHidden ? 0.15 : 0.4))

            Image(systemName: action.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent.opacity(isHidden ? 0.45 : 1.0))
                .frame(width: 22)

            Text(action.displayName)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(isHidden ? Color.white.opacity(0.55) : .white)

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { !isHidden },
                set: { newValue in
                    haptics.play()
                    if newValue {
                        if !order.contains(action) {
                            order.append(action)
                        }
                    } else {
                        order.removeAll { $0 == action }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle(tint: accent))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isHidden ? 0.03 : 0.06))
        )
        .contextMenu {
            if !isHidden {
                Button {
                    moveUp(action)
                } label: {
                    Label("Move up", systemImage: "arrow.up")
                }
                .disabled(order.first == action)
                Button {
                    moveDown(action)
                } label: {
                    Label("Move down", systemImage: "arrow.down")
                }
                .disabled(order.last == action)
            }
        }
    }

    private func moveUp(_ action: MercuryQuickAction) {
        guard let index = order.firstIndex(of: action), index > 0 else { return }
        order.swapAt(index, index - 1)
        haptics.play()
    }

    private func moveDown(_ action: MercuryQuickAction) {
        guard let index = order.firstIndex(of: action), index < order.count - 1 else { return }
        order.swapAt(index, index + 1)
        haptics.play()
    }
}
