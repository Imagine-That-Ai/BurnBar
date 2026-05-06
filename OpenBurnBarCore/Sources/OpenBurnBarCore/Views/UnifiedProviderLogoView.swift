/// Cross-platform provider logo view.
/// Uses bundled asset catalog images on both macOS and iOS with SF Symbol fallback.
///
/// Many bundled provider logos (OpenAI, Cursor, Forge, Anthropic, etc.) ship
/// as solid dark glyphs designed for light backgrounds. To keep them legible
/// on the app's warm-charcoal dark surface, we render them on top of a
/// neutral light disc in dark mode so the silhouette retains contrast.
import SwiftUI

public struct UnifiedProviderLogoView: View {
    public let provider: AgentProvider
    public let size: CGFloat
    public let useFallbackColor: Bool

    @Environment(\.colorScheme) private var colorScheme

    public init(provider: AgentProvider, size: CGFloat = 24, useFallbackColor: Bool = true) {
        self.provider = provider
        self.size = size
        self.useFallbackColor = useFallbackColor
    }

    public var body: some View {
        ZStack {
            if needsBackdropTreatment {
                logoBackdrop
            }
            Group {
                if let image = bundledImage {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(needsBackdropTreatment ? size * 0.08 : 0)
                } else {
                    fallbackView
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
    }

    // MARK: - Adaptive Backdrop

    /// Logos that ship as solid dark glyphs and need a light disc behind
    /// them in dark mode. We do not list every brand here — only the ones
    /// confirmed monochrome-dark in our asset catalog.
    private var needsBackdropTreatment: Bool {
        guard colorScheme == .dark, bundledImage != nil else { return false }
        switch provider {
        case .openAI, .codex, .cursor, .forgeDev, .claudeCode,
             .factory, .windsurf, .copilot, .aider, .ollama,
             .openClaw, .geminiCLI, .goose, .augment, .cline,
             .kiloCode, .rooCode, .hermes:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var logoBackdrop: some View {
        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(.white.opacity(0.92))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
            )
    }

    // MARK: - Bundled Image

    private var bundledImage: Image? {
        let name = provider.bundledLogoName
        #if canImport(AppKit)
        if NSImage(named: name) != nil {
            return Image(name)
        }
        #elseif canImport(UIKit)
        if UIImage(named: name) != nil {
            return Image(name)
        }
        #endif
        return nil
    }

    // MARK: - Fallback

    @ViewBuilder
    private var fallbackView: some View {
        let color = useFallbackColor ? UnifiedDesignSystem.Colors.primary(for: provider) : nil
        Image(systemName: provider.iconName)
            .font(.system(size: size * 0.6, weight: .semibold))
            .foregroundStyle(color ?? .primary)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 20) {
        ForEach(AgentProvider.allCases) { provider in
            HStack {
                UnifiedProviderLogoView(provider: provider, size: 32)
                Text(provider.displayName)
                Spacer()
            }
            .padding()
        }
    }
    .padding()
}
#endif
