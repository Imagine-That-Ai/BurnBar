import SwiftUI

/// A view that displays a provider's logo from lobehub or falls back to SF Symbol
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
            if let logoURL = provider.logoURL {
                AsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .empty:
                        fallbackView
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        fallbackView
                    @unknown default:
                        fallbackView
                    }
                }
            } else {
                fallbackView
            }
        }
        .frame(width: size, height: size)
        // iOS-style squircle (continuous corner) — avoids harsh square logos (e.g. Factory) in circular wells.
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
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
                if provider.logoURL != nil {
                    Text("Logo")
                        .foregroundStyle(.green)
                } else {
                    Text("SF Symbol")
                        .foregroundStyle(.orange)
                }
            }
            .padding()
        }
    }
    .padding()
}
