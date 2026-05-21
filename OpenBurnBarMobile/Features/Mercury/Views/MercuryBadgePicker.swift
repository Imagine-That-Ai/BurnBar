import SwiftUI

/// Wrap-style chip cloud where the user picks up to two badge kinds.
/// Adding a third triggers a soft haptic and silently drops the oldest
/// pick — feels physical without modal alerts.
struct MercuryBadgePicker: View {
    @Binding var selection: [MercuryBadgeKind]
    let accent: Color
    let haptics: MercuryHapticsLevel

    static let maxSelection = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 8) {
                ForEach(MercuryBadgeKind.allCases) { kind in
                    chip(for: kind)
                }
            }
            Text("Pick up to two badges. Some kinds (Battery, Hostname, IP, Foreground app) light up once your Mac advertises them — for now they render a placeholder.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.4))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func chip(for kind: MercuryBadgeKind) -> some View {
        let isSelected = selection.contains(kind)
        Button {
            toggle(kind)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: kind.icon)
                    .font(.system(size: 11))
                Text(kind.displayName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                if !kind.isCurrentlyResolvable {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .foregroundStyle(isSelected ? .white : Color.white.opacity(0.7))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(isSelected ? 0.14 : 0.06))
                    .overlay(
                        Capsule()
                            .stroke(accent.opacity(isSelected ? 0.7 : 0.0), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggle(_ kind: MercuryBadgeKind) {
        if let index = selection.firstIndex(of: kind) {
            selection.remove(at: index)
            haptics.play()
        } else if selection.count >= Self.maxSelection {
            // Drop the oldest pick so the new one slots in.
            selection.removeFirst()
            selection.append(kind)
            haptics.play()
        } else {
            selection.append(kind)
            haptics.play()
        }
    }
}

/// Minimal flow layout for the badge chip cloud. Re-implementing because
/// `Layout` requires iOS 16+ which the rest of the screen already
/// targets, and pulling in a third-party flowlayout is overkill.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
            totalWidth = max(totalWidth, rowWidth)
        }
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
