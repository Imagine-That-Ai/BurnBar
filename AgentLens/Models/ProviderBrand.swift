import SwiftUI
import OpenBurnBarCore

/// Unified branding metadata for any provider — works for both `AgentProvider` (switcher surface)
/// and catalog providers (daemon routed surface). Decoupled from either enum so
/// daemon catalog providers can render logos without mapping to `AgentProvider`.
struct ProviderBrand: Hashable, Identifiable {
    let id: String
    let displayName: String
    let bundledLogoName: String
    let bundledLogoCandidates: [String]
    let accentColor: Color
    let iconName: String

    /// Whether this brand has a real bundled logo (vs just an SF Symbol).
    var hasBundledLogo: Bool {
        resolvedBundledLogoName != nil
    }

    var resolvedBundledLogoName: String? {
        bundledLogoCandidates.first { NSImage(named: $0) != nil }
    }

    /// Build a brand from an `AgentProvider` (switcher surface).
    init(from provider: AgentProvider) {
        self.id = provider.rawValue
        self.displayName = provider.displayName
        self.bundledLogoName = provider.bundledLogoName
        self.bundledLogoCandidates = [provider.bundledLogoName]
        self.accentColor = DesignSystem.Colors.primary(for: provider)
        self.iconName = provider.iconName
    }

    /// Build a brand from a catalog provider (daemon routed surface).
    init(from catalogProvider: BurnBarCatalogProvider) {
        self.id = catalogProvider.id
        self.displayName = catalogProvider.displayName
        self.bundledLogoName = catalogProvider.bundledLogoName
        self.bundledLogoCandidates = Self.logoAssetCandidates(
            for: catalogProvider.id,
            registeredLogoName: catalogProvider.bundledLogoName
        )
        self.accentColor = Self.colorForProviderID(catalogProvider.id)
        self.iconName = Self.iconForProviderID(catalogProvider.id)
    }

    /// Build from a raw provider ID string (resolves from catalog or falls back).
    init(providerID: String) {
        self.id = providerID
        if let catalogProvider = BurnBarCatalogLoader.bundledCatalog.provider(id: providerID) {
            self.displayName = catalogProvider.displayName
            self.bundledLogoName = catalogProvider.bundledLogoName
            self.bundledLogoCandidates = Self.logoAssetCandidates(
                for: catalogProvider.id,
                registeredLogoName: catalogProvider.bundledLogoName
            )
            self.accentColor = Self.colorForProviderID(providerID)
            self.iconName = Self.iconForProviderID(providerID)
        } else {
            self.displayName = providerID.capitalized
            self.bundledLogoName = BurnBarCatalogProvider.bundledLogoName(forProviderID: providerID)
                ?? "\(providerID.capitalized)Logo"
            self.bundledLogoCandidates = Self.logoAssetCandidates(
                for: providerID,
                registeredLogoName: self.bundledLogoName
            )
            self.accentColor = DesignSystem.Colors.textSecondary
            self.iconName = "cube.transparent"
        }
    }
}

// MARK: - Provider Brand Registry

extension ProviderBrand {
    /// Asset names worth probing for a provider ID. Real brand marks are tried
    /// before older synthetic `*ProviderLogo` placeholders, while the catalog's
    /// registered logo remains a stable fallback for future providers.
    static func logoAssetCandidates(
        for providerID: String,
        registeredLogoName: String? = nil
    ) -> [String] {
        let normalized = providerID
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []

        switch normalized {
        case "anthropic", "claude", "claude-code":
            candidates.append(contentsOf: ["AnthropicLogo", "ClaudeCodeLogo"])
        case "openai", "open-ai", "codex":
            candidates.append(contentsOf: ["OpenAILogo", "CodexLogo"])
        case "opencode", "open-code":
            candidates.append("OpenCodeLogo")
        case "antigravity", "antigravitycli", "antigravity-cli":
            candidates.append(contentsOf: ["AntigravityLogo", "GoogleLogo", "GeminiCLILogo"])
        case "google", "gemini", "gemini-cli":
            candidates.append(contentsOf: ["GoogleLogo", "GeminiCLILogo"])
        case "xai", "grok", "x-ai":
            candidates.append("GrokLogo")
        case "deepseek", "deep-seek":
            candidates.append(contentsOf: ["DeepSeekLogo", "DeepSeekProviderLogo"])
        case "mistral":
            candidates.append(contentsOf: ["MistralLogo", "MistralProviderLogo"])
        case "meta", "llama", "muse", "metamuse", "muse-spark":
            candidates.append(contentsOf: ["MetaLogo", "MetaProviderLogo", "MuseLogo"])
        case "cohere":
            candidates.append(contentsOf: ["CohereLogo", "CohereProviderLogo"])
        case "amazon", "aws", "bedrock":
            candidates.append(contentsOf: ["AmazonLogo", "AmazonProviderLogo"])
        case "alibaba", "qwen", "dashscope":
            candidates.append(contentsOf: ["QwenLogo", "AlibabaLogo", "AlibabaProviderLogo"])
        case "zai", "z-ai", "z.ai", "glm":
            candidates.append(contentsOf: ["ZaiLogo", "ZaiProviderLogo"])
        // Desktop twins share the CLI provider's artwork — same brand, different surface.
        // This mirrors `BurnBarCatalogProvider.bundledLogoName(forProviderID:)`, which
        // already maps every `*-desktop` id onto the base provider's asset.
        case "zcode", "zcode-desktop", "z-code", "z.ai-desktop", "zai-desktop":
            candidates.append(contentsOf: ["ZaiLogo", "ZaiProviderLogo"])
        case "minimax", "mini-max", "minimax-desktop", "minimax desktop", "minimax-agent":
            candidates.append("MiniMaxLogo")
        case "mimo", "xiaomi", "xiaomimimo":
            candidates.append("MimoLogo")
        case "factory-desktop", "factory desktop":
            candidates.append("FactoryLogo")
        case "devin", "devin-desktop", "devin desktop", "devin-cli", "devin cli":
            candidates.append("DevinLogo")
        case "claude-desktop", "claude desktop":
            candidates.append(contentsOf: ["ClaudeCodeLogo", "AnthropicLogo"])
        case "warp-desktop", "warp desktop", "warp-terminal":
            candidates.append("WarpLogo")
        case "ollama-desktop", "ollama desktop":
            candidates.append("OllamaLogo")
        case "codex-desktop", "codex desktop":
            candidates.append(contentsOf: ["CodexLogo", "OpenAILogo"])
        case "cursor-desktop", "cursor desktop", "cursor-ide":
            candidates.append("CursorLogo")
        case "hermes-desktop", "hermes desktop", "hermes-dashboard":
            candidates.append("HermesLogo")
        case "prime", "prime-agent", "primeagent", "prime_agent", "prime agent":
            candidates.append("PrimeAgentLogo")
        case "cursor-agent", "cursoragent":
            candidates.append("CursorLogo")
        case "fx":
            candidates.append("FxLogo")
        case "moonshot", "kimi":
            candidates.append(contentsOf: ["KimiLogo", "MoonshotLogo", "KimiProviderLogo"])
        case "mlx":
            candidates.append("MLXLogo")
        case "ollama":
            candidates.append("OllamaLogo")
        case "perplexity":
            candidates.append("PerplexityLogo")
        case "apple":
            candidates.append("AppleLogo")
        default:
            break
        }

        if let registeredLogoName,
           !registeredLogoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(registeredLogoName)
        }
        if let registered = BurnBarCatalogProvider.bundledLogoName(forProviderID: normalized) {
            candidates.append(registered)
        }
        if !normalized.isEmpty {
            let conventional = normalized
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined() + "Logo"
            candidates.append(conventional)
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// Deterministic accent color for any provider ID.
    static func colorForProviderID(_ id: String) -> Color {
        switch id.lowercased() {
        case "anthropic":   return Color(hex: "CC785C")
        case "openai":      return Color(hex: "00A67E")
        case "factory":     return Color(hex: "F97316")
        case "google":      return Color(hex: "4285F4")
        case "antigravity", "antigravitycli", "antigravity-cli": return Color(hex: "6C63FF")
        case "xai":         return Color(hex: "1A1A2E")
        case "deepseek":    return Color(hex: "6366F1")
        case "mistral":     return Color(hex: "FF7000")
        case "meta", "muse", "metamuse": return Color(hex: "0668E1")
        case "cohere":      return Color(hex: "39594D")
        case "amazon":      return Color(hex: "FF9900")
        case "alibaba":     return Color(hex: "FF6A00")
        case "zai":         return Color(hex: "8B5CF6")
        case "zcode", "zcode-desktop", "z.ai-desktop", "zai-desktop": return Color(hex: "7C3AED")
        case "minimax":     return Color(hex: "F59E0B")
        case "minimax-desktop", "minimax-agent": return Color(hex: "F59E0B")
        case "factory-desktop": return Color(hex: "8B5CF6")
        case "devin", "devin-desktop", "devin-cli": return Color(hex: "0A84FF")
        case "claude-desktop": return Color(hex: "CC785C")
        case "warp-desktop": return Color(hex: "DDE4EA")
        case "ollama-desktop": return Color(hex: "8B8589")
        case "codex-desktop": return Color(hex: "2563EB")
        case "cursor-desktop": return Color(hex: "AC8C57")
        case "hermes-desktop": return Color(hex: "A855F7")
        case "mimo", "xiaomi", "xiaomimimo":
            return Color(hex: "FF6900")
        case "ollama":      return Color(hex: "8B8589")
        case "moonshot":    return Color(hex: "6366F1")
        case "prime", "prime-agent", "primeagent": return Color(hex: "582CFF")
        case "cursor-agent", "cursoragent": return Color(hex: "00E5FF")
        case "fx":          return Color(hex: "A1A1AA")
        case "misc":        return DesignSystem.Colors.textSecondary
        default:            return DesignSystem.Colors.textSecondary
        }
    }

    /// Deterministic SF Symbol fallback for any provider ID.
    static func iconForProviderID(_ id: String) -> String {
        switch id.lowercased() {
        case "anthropic":   return "bubble.left.and.bubble.right.fill"
        case "openai":      return "hammer.fill"
        case "factory":     return "gearshape.2.fill"
        case "google":      return "diamond.fill"
        case "antigravity", "antigravitycli", "antigravity-cli": return "sparkles"
        case "xai":         return "bolt.fill"
        case "deepseek":    return "brain.head.profile"
        case "mistral":     return "wind"
        case "meta", "muse", "metamuse": return "brain.head.profile"
        case "cohere":      return "text.bubble.fill"
        case "amazon":      return "box.fill"
        case "alibaba":     return "cloud.fill"
        case "zai":         return "bolt.fill"
        case "zcode", "zcode-desktop", "z.ai-desktop", "zai-desktop": return "bolt.fill"
        case "minimax":     return "star.fill"
        case "minimax-desktop", "minimax-agent": return "star.fill"
        case "factory-desktop": return "cpu.fill"
        case "devin", "devin-desktop", "devin-cli": return "desktopcomputer"
        case "claude-desktop": return "bubble.left.and.bubble.right.fill"
        case "warp-desktop": return "terminal.fill"
        case "ollama-desktop": return "server.rack"
        case "codex-desktop": return "hammer.fill"
        case "cursor-desktop": return "cursor.rays"
        case "hermes-desktop": return "wind"
        case "ollama":      return "server.rack"
        case "moonshot":    return "moon.fill"
        case "prime", "prime-agent", "primeagent": return "arrow.triangle.2.circlepath"
        case "cursor-agent", "cursoragent": return "cursor.rays"
        case "fx":          return "forward.fill"
        case "misc":        return "cube.transparent"
        default:            return "cube.transparent"
        }
    }
}

// MARK: - CatalogLogoView

/// Logo view that works with any catalog provider ID — uses bundled assets.
struct CatalogProviderLogoView: View {
    let brand: ProviderBrand
    let size: CGFloat

    init(brand: ProviderBrand, size: CGFloat = 24) {
        self.brand = brand
        self.size = size
    }

    init(providerID: String, size: CGFloat = 24) {
        self.brand = ProviderBrand(providerID: providerID)
        self.size = size
    }

    var body: some View {
        Group {
            if let logoName = brand.resolvedBundledLogoName {
                Image(logoName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: brand.iconName)
                    .font(.system(size: size * 0.6, weight: .semibold))
                    .foregroundStyle(brand.accentColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
    }
}
