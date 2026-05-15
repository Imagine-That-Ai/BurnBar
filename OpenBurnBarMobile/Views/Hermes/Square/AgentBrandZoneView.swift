import SwiftUI
import OpenBurnBarCore

// MARK: - Agent Brand Zone (Hermes Square §6.3)
//
// Per-agent canonical page — the "WeChat brand zone" applied to agents.
// Hero strip, quick actions, capability pills, last-7-days strip,
// persona slots, about / source / version / scopes.

struct AgentBrandZoneView: View {
    let identity: AgentIdentity
    @Bindable var registry: AgentIdentityRegistry

    @Environment(\.motionStore) private var motionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Color(hex: identity.paletteHex) }

    /// How much the hero avatar drifts at full device tilt. Subtle — we
    /// want the parallax to be felt, not seen.
    private let heroParallaxIntensity: CGFloat = 10

    /// The gradient backdrop moves opposite to the avatar at half the
    /// intensity for a layered, depth-of-field feel.
    private let backdropParallaxIntensity: CGFloat = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                quickActions
                capabilities
                lastSevenDays
                personas
                about
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(EmberSurfaceBackground().ignoresSafeArea())
        .navigationTitle(identity.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // Acquire / release the motion stream while this brand zone is
        // on-screen so the gyroscope only runs when we're actually
        // rendering the parallax.
        .onAppear { motionStore.acquire(reduceMotion: reduceMotion) }
        .onDisappear { motionStore.release() }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 14) {
            ZStack {
                // Backdrop gradient ring drifts opposite to the avatar
                // for a depth-of-field layered feel. Honors Reduce
                // Motion via the modifier.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.32), accent.opacity(0.06), .clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: 56
                        )
                    )
                    .frame(width: 92, height: 92)
                    .offset(parallaxOffset(intensity: -backdropParallaxIntensity))
                // Real brand logo (bundled asset) replaces the gradient
                // disc + glyph for built-in runtimes. User-installed
                // agents whose vendor doesn't match a known provider
                // fall back to the gradient-and-glyph treatment inside
                // `HermesSquareAgentAvatar`.
                HermesSquareAgentAvatar(
                    identity: identity,
                    size: 64,
                    showAvailability: false,
                    ringStroke: true
                )
                .offset(parallaxOffset(intensity: heroParallaxIntensity))
            }
            .frame(width: 92, height: 92)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(identity.displayName)
                        .font(.title2.bold())
                        .foregroundStyle(DesignSystemColors.textPrimary)
                    Text(identity.tier.displayLabel)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.18)))
                        .foregroundStyle(accent)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(availabilityColor)
                        .frame(width: 7, height: 7)
                    Text(identity.availability.displayLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
                if let tagline = identity.tagline {
                    Text(tagline)
                        .font(.callout)
                        .foregroundStyle(DesignSystemColors.textSecondary)
                }
            }
            Spacer()
        }
    }

    private var availabilityColor: Color {
        switch identity.availability {
        case .online:    return DesignSystemColors.success
        case .degraded:  return DesignSystemColors.warning
        case .offline:   return DesignSystemColors.error
        case .unknown:   return DesignSystemColors.textMuted
        }
    }

    /// CGSize derived from the shared `MotionStore`'s tilt. Reduce Motion
    /// zeroes this out automatically.
    private func parallaxOffset(intensity: CGFloat) -> CGSize {
        guard !reduceMotion else { return .zero }
        return CGSize(
            width: motionStore.tilt.width * intensity,
            height: motionStore.tilt.height * intensity
        )
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 8) {
            quickAction(label: "New thread", systemImage: "plus.bubble") { }
            quickAction(label: "Dispatch", systemImage: "paperplane.fill") { }
            quickAction(label: "Forward", systemImage: "arrowshape.turn.up.right.fill") { }
            quickAction(label: "Subscribe", systemImage: "bell.fill") { }
        }
    }

    private func quickAction(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .foregroundStyle(accent)
                Text(label)
                    .font(.caption2.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(DesignSystemColors.surface.opacity(0.6))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Capability pills

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Capabilities")
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textSecondary)
            let pills = identity.capabilities.displayPills
            if pills.isEmpty {
                Text("No declared capabilities yet.")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(pills, id: \.self) { pill in
                        Text(pill)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(accent.opacity(0.14))
                            )
                            .foregroundStyle(accent)
                    }
                }
            }
        }
    }

    // MARK: Last 7 days

    private var lastSevenDays: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last 7 days")
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textSecondary)
            if let stats = identity.lastSevenDays {
                HStack(spacing: 16) {
                    statBlock(label: "Threads",  value: "\(stats.threadCount)")
                    statBlock(label: "Missions", value: "\(stats.missionCount)")
                    statBlock(label: "Burn",     value: MissionConsoleFormatting.cost(stats.burnUSD))
                    statBlock(label: "Success",  value: String(format: "%.0f%%", stats.successRate * 100))
                }
            } else {
                Text("No telemetry yet — start a thread or dispatch a mission.")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
        }
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(DesignSystemColors.textMuted)
            Text(value).font(.callout.bold()).foregroundStyle(DesignSystemColors.textPrimary)
        }
    }

    // MARK: Personas

    private var personas: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Personas")
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textSecondary)
            if identity.personas.isEmpty {
                Text("Default persona only.")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
            } else {
                ForEach(identity.personas) { persona in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(persona.name).font(.callout.bold())
                                    .foregroundStyle(DesignSystemColors.textPrimary)
                                if persona.isDefault {
                                    Text("default")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(accent.opacity(0.16)))
                                        .foregroundStyle(accent)
                                }
                            }
                            Text(persona.description)
                                .font(.caption)
                                .foregroundStyle(DesignSystemColors.textMuted)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystemColors.surface.opacity(0.5))
                    )
                }
            }
        }
    }

    // MARK: About

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About")
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                row(label: "URI", value: identity.id)
                row(label: "Install", value: identity.installSource.displayLabel)
                row(label: "Transport", value: identity.dispatchTransport.displayLabel)
                if let lastRefreshedAt = identity.lastRefreshedAt {
                    row(label: "Last refreshed", value: MissionConsoleFormatting.relativeTime(lastRefreshedAt))
                }
            }
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textMuted)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(DesignSystemColors.textSecondary)
                .multilineTextAlignment(.leading)
            Spacer()
        }
    }
}

// MARK: - Minimal FlowLayout shim (capability pills)

private struct FlowLayout: Layout {
    var spacing: CGFloat

    init(spacing: CGFloat = 6) {
        self.spacing = spacing
    }

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
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
