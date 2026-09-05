import SwiftUI

/// A view that displays a provider's bundled logo with SF Symbol fallback.
/// All providers now ship with bundled assets — no remote URL loading.
struct ProviderLogoView: View {
    let provider: AgentProvider
    let size: CGFloat
    let useFallbackColor: Bool
    /// Overrides the color scheme used to decide the monochrome-logo backdrop.
    /// Pass `.dark` when the logo sits on always-dark chrome (e.g. the command
    /// deck's glass rail) even while the app is in a light appearance, so dark
    /// glyphs still get their contrast disc. `nil` follows the environment.
    let surfaceScheme: ColorScheme?

    @Environment(\.colorScheme) private var colorScheme

    init(
        provider: AgentProvider,
        size: CGFloat = 24,
        useFallbackColor: Bool = true,
        surfaceScheme: ColorScheme? = nil
    ) {
        self.provider = provider
        self.size = size
        self.useFallbackColor = useFallbackColor
        self.surfaceScheme = surfaceScheme
    }

    /// The scheme that governs contrast treatment — the caller's declared
    /// surface if given, otherwise the ambient appearance.
    private var effectiveScheme: ColorScheme { surfaceScheme ?? colorScheme }

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
                        .frame(maxWidth: size, maxHeight: size)
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
        return provider.needsMonochromeLogoBackdrop(colorScheme: effectiveScheme)
    }

    @ViewBuilder
    private var logoBackdrop: some View {
        let fillStyle: AnyShapeStyle = {
            if effectiveScheme == .dark {
                return AnyShapeStyle(.white.opacity(0.92))
            } else {
                return AnyShapeStyle(DesignSystem.Colors.primary(for: provider))
            }
        }()

        RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
            .fill(fillStyle)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                    .stroke(effectiveScheme == .dark ? Color.black.opacity(0.06) : Color.white.opacity(0.12), lineWidth: 0.5)
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
                .frame(width: size, height: size)
        } else {
            Image(systemName: provider.iconName)
                .font(.system(size: size * 0.6, weight: .semibold))
                .frame(width: size, height: size)
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
