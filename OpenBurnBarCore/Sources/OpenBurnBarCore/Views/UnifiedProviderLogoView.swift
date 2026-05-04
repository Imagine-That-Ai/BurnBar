import SwiftUI

/// Cross-platform provider logo view.
/// Uses bundled asset catalog images on both macOS and iOS with SF Symbol fallback.
public struct UnifiedProviderLogoView: View {
    public let provider: AgentProvider
    public let size: CGFloat
    public let useFallbackColor: Bool

    public init(provider: AgentProvider, size: CGFloat = 24, useFallbackColor: Bool = true) {
        self.provider = provider
        self.size = size
        self.useFallbackColor = useFallbackColor
    }

    public var body: some View {
        Group {
            if let image = bundledImage {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                fallbackView
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
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
