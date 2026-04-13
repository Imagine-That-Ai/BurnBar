import SwiftUI

/// A view that displays a provider's bundled logo with SF Symbol fallback.
/// All providers now ship with bundled assets — no remote URL loading.
struct ProviderLogoView: View {
    let provider: AgentProvider
    let size: CGFloat
    let useFallbackColor: Bool

    init(provider: AgentProvider, size: CGFloat = 24, useFallbackColor: Bool = true) {
        self.provider = provider
        self.size = size
        self.useFallbackColor = useFallbackColor
    }

    var body: some View {
        Group {
            if let bundledImage {
                bundledImage
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                fallbackView
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
    }

    @ViewBuilder
    private var bundledImage: Image? {
        let name = provider.bundledLogoName
        // Verify the asset exists at runtime; fall back gracefully if missing
        if NSImage(named: name) != nil {
            return Image(name)
        }
        return nil
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
