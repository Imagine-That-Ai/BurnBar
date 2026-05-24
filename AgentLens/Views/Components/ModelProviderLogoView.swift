import SwiftUI

/// Brand mark for the LLM vendor behind a model id (Anthropic, OpenAI, etc.).
/// Uses bundled logo assets — no remote URL loading.
struct ModelProviderLogoView: View {
    let modelKey: String
    let size: CGFloat
    /// Tint for the SF Symbol when there is no bundled logo; `nil` uses `LLMModelBrand.emblemColor`.
    var fallbackSymbolColor: Color?

    init(modelKey: String, size: CGFloat = 22, fallbackSymbolColor: Color? = nil) {
        self.modelKey = modelKey
        self.size = size
        self.fallbackSymbolColor = fallbackSymbolColor
    }

    private var isRouted: Bool {
        let key = modelKey.lowercased()
        return key.contains("openburnbar") || key.contains("burnbar")
    }

    private var brand: LLMModelBrand {
        if isRouted {
            let cleanedKey = modelKey
                .lowercased()
                .replacingOccurrences(of: "openburnbar", with: "")
                .replacingOccurrences(of: "burnbar", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-/_"))
            let inferred = LLMModelBrand.infer(fromModelKey: cleanedKey)
            if inferred == .unknown || inferred == .openBurnBar {
                return .unknown
            }
            return inferred
        } else {
            return LLMModelBrand.infer(fromModelKey: modelKey)
        }
    }

    private var symbolTint: Color {
        fallbackSymbolColor ?? brand.emblemColor
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Base vendor logo
            Group {
                if brand.hasBundledLogo {
                    Image(brand.bundledLogoName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: brand.sfSymbolFallback)
                        .font(.system(size: size * 0.52, weight: .medium))
                        .foregroundStyle(symbolTint)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))

            // OpenBurnBar routing badge overlay
            if isRouted {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: size * 0.48, height: size * 0.48)
                        .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 0.5)

                    Image("AppLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size * 0.40, height: size * 0.40)
                }
                .offset(x: size * 0.15, y: size * 0.15)
            }
        }
        .padding(isRouted ? size * 0.12 : 0)
        .frame(width: size, height: size)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 16) {
        ForEach(["claude-opus-4", "gpt-4o", "gemini-2.0-flash", "unknown-model"], id: \.self) { id in
            HStack {
                ModelProviderLogoView(modelKey: id, size: 28)
                Text(id)
            }
        }
    }
    .padding()
}
