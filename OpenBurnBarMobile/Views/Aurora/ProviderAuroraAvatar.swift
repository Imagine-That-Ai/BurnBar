import SwiftUI
import OpenBurnBarCore

// MARK: - Provider Aurora Avatar
//
// Premium provider avatar with rotating angular ring, soft halo, and inner
// glass containing the bundled logo. Used by Pulse hero, Burn rings, and any
// place a provider deserves a "presence" treatment.

struct ProviderAuroraAvatar: View {
    let provider: AgentProvider
    var size: CGFloat = 64
    var animated: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ringRotation: Double = 0

    private var primary: Color { MobileTheme.Colors.primary(for: provider) }
    private var accent: Color { MobileTheme.Colors.accent(for: provider) }

    var body: some View {
        ZStack {
            halo
            ring
            glassDisc
            logo
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
        .onAppear { startRing() }
        .onChange(of: reduceMotion) { _, _ in startRing() }
    }

    // MARK: - Layers

    private var halo: some View {
        RadialGradient(
            colors: [primary.opacity(0.45), Color.clear],
            center: .center,
            startRadius: 0,
            endRadius: size * 0.85
        )
        .frame(width: size * 1.6, height: size * 1.6)
        .blur(radius: 4)
    }

    private var ring: some View {
        Circle()
            .strokeBorder(
                AuroraDesign.Gradients.providerRing(for: provider),
                lineWidth: max(2, size * 0.04)
            )
            .rotationEffect(.degrees(ringRotation))
            .frame(width: size, height: size)
            .shadow(color: primary.opacity(0.55), radius: 8, y: 0)
    }

    @ViewBuilder
    private var glassDisc: some View {
        let inset: CGFloat = max(6, size * 0.14)
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.55),
                                accent.opacity(0.35)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
            .padding(inset)
    }

    private var logo: some View {
        UnifiedProviderLogoView(provider: provider, size: size * 0.5, useFallbackColor: false)
            .frame(width: size * 0.5, height: size * 0.5)
    }

    // MARK: - Animation

    private func startRing() {
        guard animated, !reduceMotion else {
            ringRotation = 0
            return
        }
        withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
            ringRotation = 360
        }
    }
}

#Preview {
    ZStack {
        AuroraBackdrop()
        HStack(spacing: 24) {
            ProviderAuroraAvatar(provider: .claudeCode, size: 88)
            ProviderAuroraAvatar(provider: .openAI, size: 64)
            ProviderAuroraAvatar(provider: .factory, size: 56)
        }
    }
}
