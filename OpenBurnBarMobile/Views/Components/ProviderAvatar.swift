import SwiftUI
import OpenBurnBarCore

// MARK: - Provider Avatar

/// Canonical provider avatar component that replaces `ProviderBadge` everywhere.
/// Loads bundled images via `UnifiedProviderLogoView` with three display modes.
struct ProviderAvatar: View {
    let provider: AgentProvider
    var mode: DisplayMode = .tile
    var size: CGFloat = 40

    enum DisplayMode {
        /// Bare logo, no container — for inline chips.
        case plain
        /// Rounded square with subtle stroke — default for list rows.
        case tile
        /// Haloed circle with gradient ring + glass — for hero cards.
        case aurora
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var themeColor: Color {
        UnifiedDesignSystem.Colors.primary(for: provider)
    }

    private var hasBundledImage: Bool {
        #if canImport(UIKit)
        UIImage(named: provider.bundledLogoName) != nil
        #else
        true
        #endif
    }

    var body: some View {
        ZStack {
            if mode == .aurora {
                auroraBackground
            }

            logoContent
                .frame(width: logoSize, height: logoSize)
        }
        .frame(width: containerSize, height: containerSize)
        .accessibilityLabel(provider.displayName)
    }

    // MARK: - Logo Content

    @ViewBuilder
    private var logoContent: some View {
        if hasBundledImage {
            UnifiedProviderLogoView(provider: provider, size: logoSize, useFallbackColor: false)
        } else {
            Image(systemName: provider.iconName)
                .font(.system(size: logoSize * 0.5, weight: .semibold))
                .foregroundStyle(themeColor)
        }
    }

    // MARK: - Aurora Background

    @ViewBuilder
    private var auroraBackground: some View {
        ZStack {
            // Soft radial glow
            RadialGradient(
                colors: [
                    themeColor.opacity(colorScheme == .dark ? 0.35 : 0.22),
                    themeColor.opacity(0.0)
                ],
                center: .center,
                startRadius: 0,
                endRadius: containerSize * 0.6
            )
            .frame(width: containerSize * 1.4, height: containerSize * 1.4)

            // Glass container
            if #available(iOS 26.0, *) {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .stroke(auroraStrokeGradient, lineWidth: 1.5)
                    )
                    .glassEffect(.regular)
            } else {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle()
                            .stroke(auroraStrokeGradient, lineWidth: 1.5)
                    )
            }
        }
    }

    private var auroraStrokeGradient: LinearGradient {
        LinearGradient(
            colors: [
                themeColor.opacity(0.8),
                UnifiedDesignSystem.Colors.accent(for: provider).opacity(0.5)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Tile Background

    @ViewBuilder
    private var tileBackground: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(themeColor.opacity(colorScheme == .dark ? 0.12 : 0.08))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .stroke(themeColor.opacity(0.25), lineWidth: 0.5)
            )
    }

    // MARK: - Sizing

    private var containerSize: CGFloat {
        switch mode {
        case .plain:  return size
        case .tile:   return size
        case .aurora: return size * 1.2
        }
    }

    private var logoSize: CGFloat {
        switch mode {
        case .plain:  return size
        case .tile:   return size * 0.65
        case .aurora: return size * 0.55
        }
    }
}

// MARK: - Preview

#Preview("All Providers") {
    ScrollView {
        VStack(spacing: 24) {
            // Tile mode
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 16) {
                ForEach(AgentProvider.allCases) { provider in
                    VStack(spacing: 4) {
                        ProviderAvatar(provider: provider, mode: .tile, size: 48)
                        Text(provider.displayName)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                }
            }

            Divider()

            // Aurora mode
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 16) {
                ForEach(AgentProvider.allCases) { provider in
                    VStack(spacing: 4) {
                        ProviderAvatar(provider: provider, mode: .aurora, size: 48)
                        Text(provider.displayName)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding()
    }
}
