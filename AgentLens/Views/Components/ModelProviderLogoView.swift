import SwiftUI

/// Brand mark for the LLM vendor behind a model id (Anthropic, OpenAI, etc.).
struct ModelProviderLogoView: View {
    let modelKey: String
    let size: CGFloat
    /// Tint for the SF Symbol when there is no remote logo; `nil` uses `LLMModelBrand.emblemColor`.
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
            if let url = brand.logoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Image(systemName: brand.sfSymbolFallback)
                            .font(.system(size: size * 0.52, weight: .medium))
                            .foregroundStyle(symbolTint.opacity(0.35))
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        fallbackSymbol
                    @unknown default:
                        fallbackSymbol
                    }
                }
            } else {
                fallbackSymbol
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
    }

    private var fallbackSymbol: some View {
        Image(systemName: brand.sfSymbolFallback)
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(symbolTint)
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
