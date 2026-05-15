import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Square Pinned Grid (Hermes Square §6.2 / Pillar 4)
//
// The 12-slot Alipay-style grid above the inbox. Each cell renders one
// pinned agent with its glyph, abbreviated name, and an availability dot.
//
// `onTap` opens the agent's thread (or brand zone for non-native runtimes).
// `onLongPress` opens the brand zone directly.

struct HermesSquarePinnedGrid: View {
    let config: PinnedAgentGridConfig
    let registry: AgentIdentityRegistry
    let onTap: (String) -> Void
    let onLongPress: (String) -> Void

    private let columns = 4
    private let cellHeight: CGFloat = 78

    var body: some View {
        let columnsLayout = Array(repeating: GridItem(.flexible(), spacing: 10), count: columns)
        LazyVGrid(columns: columnsLayout, spacing: 10) {
            ForEach(config.pinnedURIs, id: \.self) { uri in
                if let identity = registry.identity(for: uri) {
                    cell(for: identity)
                        .frame(height: cellHeight)
                        .onTapGesture { onTap(uri) }
                        .onLongPressGesture { onLongPress(uri) }
                        .accessibilityLabel("\(identity.displayName) — \(identity.availability.displayLabel)")
                }
            }
        }
    }

    private func cell(for identity: AgentIdentity) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: identity.paletteHex),
                                Color(hex: identity.paletteHex).opacity(0.66)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 38, height: 38)
                Text(identity.glyph)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if identity.availability != .unknown {
                    Circle()
                        .fill(availabilityColor(identity.availability))
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle().stroke(DesignSystemColors.background, lineWidth: 1.2)
                        )
                        .offset(x: 14, y: 14)
                }
            }
            Text(identity.displayName)
                .font(.caption2.bold())
                .foregroundStyle(DesignSystemColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignSystemColors.surface.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(DesignSystemColors.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    private func availabilityColor(_ availability: AgentIdentity.Availability) -> Color {
        switch availability {
        case .online:   return DesignSystemColors.success
        case .degraded: return DesignSystemColors.warning
        case .offline:  return DesignSystemColors.error
        case .unknown:  return DesignSystemColors.textMuted
        }
    }
}
