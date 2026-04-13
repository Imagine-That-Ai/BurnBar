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

    private var brand: LLMModelBrand { LLMModelBrand.infer(fromModelKey: modelKey) }

    private var symbolTint: Color {
        fallbackSymbolColor ?? brand.emblemColor
    }

    var body: some View {
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
