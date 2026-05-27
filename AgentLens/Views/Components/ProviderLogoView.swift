import SwiftUI

/// A view that displays a provider's bundled logo with SF Symbol fallback.
/// All providers now ship with bundled assets — no remote URL loading.
struct ProviderLogoView: View {
    let provider: AgentProvider
    let size: CGFloat
    let useFallbackColor: Bool

    @Environment(\.colorScheme) private var colorScheme

    init(provider: AgentProvider, size: CGFloat = 24, useFallbackColor: Bool = true) {
        self.provider = provider
        self.size = size
        self.useFallbackColor = useFallbackColor
    }

    var body: some View {
        ZStack {
            if needsBackdropTreatment {
                logoBackdrop
            }
            Group {
                if let bundledImage {
                    bundledImage
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

    private var needsBackdropTreatment: Bool {
        guard bundledImage != nil else { return false }
        if colorScheme == .dark {
            switch provider {
            case .openAI, .codex, .cursor, .forgeDev, .claudeCode,
                 .factory, .windsurf, .copilot, .aider, .ollama,
                 .openClaw, .geminiCLI, .antigravity, .goose, .augment, .cline,
                 .kiloCode, .rooCode, .hermes:
                return true
            default:
                return false
            }
        } else {
            // Light mode: Kimi, Goose, and Augment have white/light silhouettes and need a backdrop
            switch provider {
            case .kimi, .goose, .augment:
                return true
            default:
                return false
            }
        }
    }

    @ViewBuilder
    private var logoBackdrop: some View {
        let fillStyle: AnyShapeStyle = {
            if colorScheme == .dark {
                return AnyShapeStyle(.white.opacity(0.92))
            } else {
                return AnyShapeStyle(DesignSystem.Colors.primary(for: provider))
            }
        }()

        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(fillStyle)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .stroke(colorScheme == .dark ? Color.black.opacity(0.06) : Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }

    private var bundledImage: Image? {
        let name = provider.bundledLogoName
        // Verify the asset exists at runtime; fall back gracefully if missing
        guard NSImage(named: name) != nil else { return nil }
        return Image(name)
    }

    @ViewBuilder
    private var fallbackView: some View {
        if useFallbackColor {
            Image(systemName: provider.iconName)
                .font(.system(size: size * 0.6, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.primary(for: provider))
        } else {
            Image(systemName: provider.iconName)
                .font(.system(size: size * 0.6, weight: .semibold))
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ForEach(AgentProvider.allCases) { provider in
            HStack {
                ProviderLogoView(provider: provider, size: 32)
                Text(provider.displayName)
                Spacer()
                Text("Bundled")
                    .foregroundStyle(.green)
            }
            .padding()
        }
    }
    .padding()
}
