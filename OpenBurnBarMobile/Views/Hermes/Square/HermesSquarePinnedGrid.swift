import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Square Pinned Grid (Hermes Square §6.2 / Pillar 4)
//
// The 12-slot Alipay-style grid above the inbox. Each cell renders one
// pinned agent with its glyph, abbreviated name, and an availability dot.
//
// `onTap` opens the agent's thread (or brand zone for non-native runtimes).
// `onLongPress` opens the brand zone directly.
//
// Motion: each cell phase-animates through tap → bounce → settle on
// press. Driven by `PhaseAnimator` (iOS 17+) so the spring is crisp and
// editorial — no manual delays, no animation flag boilerplate. Reduce
// Motion is honored automatically by the modifier.

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
                    PinnedCell(
                        identity: identity,
                        cellHeight: cellHeight,
                        onTap: { onTap(uri) },
                        onLongPress: { onLongPress(uri) }
                    )
                }
            }
        }
    }
}

// MARK: - PinnedCell (with tap micro-bounce)

private struct PinnedCell: View {
    let identity: AgentIdentity
    let cellHeight: CGFloat
    let onTap: () -> Void
    let onLongPress: () -> Void

    @State private var bounceTick: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum BouncePhase: CaseIterable {
        case rest, depress, recoil, settle

        var scale: CGFloat {
            switch self {
            case .rest:    return 1.0
            case .depress: return 0.92
            case .recoil:  return 1.06
            case .settle:  return 1.0
            }
        }

        var haloOpacity: Double {
            switch self {
            case .rest:    return 0.0
            case .depress: return 0.55
            case .recoil:  return 0.32
            case .settle:  return 0.0
            }
        }

        var duration: TimeInterval {
            switch self {
            case .rest:    return 0.0
            case .depress: return 0.10
            case .recoil:  return 0.18
            case .settle:  return 0.16
            }
        }
    }

    var body: some View {
        cellBody
            .frame(height: cellHeight)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("\(identity.displayName) — \(identity.availability.displayLabel)")
            .gesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in onLongPress() }
            )
            .simultaneousGesture(
                TapGesture()
                    .onEnded {
                        if !reduceMotion { bounceTick &+= 1 }
                        onTap()
                    }
            )
    }

    @ViewBuilder
    private var cellBody: some View {
        if reduceMotion {
            decoratedCell(scale: 1, haloOpacity: 0)
        } else {
            decoratedCell(scale: 1, haloOpacity: 0)
                .phaseAnimator(BouncePhase.allCases, trigger: bounceTick) { content, phase in
                    content
                        .scaleEffect(phase.scale)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    Color(hex: identity.paletteHex).opacity(phase.haloOpacity),
                                    lineWidth: 1.4
                                )
                                .blur(radius: 0.5)
                                .allowsHitTesting(false)
                        )
                } animation: { phase in
                    switch phase {
                    case .rest:    return .linear(duration: 0)
                    case .depress: return .spring(response: 0.18, dampingFraction: 0.65)
                    case .recoil:  return .spring(response: 0.22, dampingFraction: 0.55)
                    case .settle:  return .spring(response: 0.30, dampingFraction: 0.75)
                    }
                }
        }
    }

    private func decoratedCell(scale: CGFloat, haloOpacity: Double) -> some View {
        VStack(spacing: 6) {
            HermesSquareAgentAvatar(
                identity: identity,
                size: 38,
                showAvailability: true,
                ringStroke: true
            )
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
        .scaleEffect(scale)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(hex: identity.paletteHex).opacity(haloOpacity), lineWidth: 1.4)
                .blur(radius: 0.5)
                .allowsHitTesting(false)
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
