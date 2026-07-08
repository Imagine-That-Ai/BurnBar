import AppKit
import OpenBurnBarCore
import SwiftUI

/// Logo resolver for the proxy catalog. The advertised provider IDs come
/// straight from `BurnBarCatalogProvider.id` (e.g. `deepseek`, `xai`,
/// `mistral`, `meta`, `alibaba`, `mlx`, `cohere`, `amazon`) — most of which
/// have no `AgentProvider` case but DO ship asset-catalog logos. We resolve
/// in this order:
///   1. Bundled asset whose name matches `BurnBarCatalogProvider`'s registry
///      (`DeepSeekProviderLogo`, `GrokLogo`, etc.) or the unsuffixed variant
///      (`DeepSeekLogo`).
///   2. The `AgentProvider`-mapped `ProviderLogoView` for canonical cases
///      (`anthropic` → `.claudeCode`, `openai` → `.openAI`, etc.).
///   3. A monogram badge tinted with `DesignSystem.Colors.primary(for:)` when
///      we can derive a provider, otherwise the textMuted fallback.
struct ProxyProviderLogoView: View {
    let catalogProviderID: String
    let providerName: String
    let size: CGFloat

    private var assetImage: Image? {
        for candidate in Self.assetCandidates(for: catalogProviderID) where NSImage(named: candidate) != nil {
            return Image(candidate)
        }
        return nil
    }

    private var agentProvider: AgentProvider? {
        AgentProvider.fromCatalogProviderID(catalogProviderID)
    }

    var body: some View {
        Group {
            if let assetImage {
                assetImage
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
            } else if let provider = agentProvider {
                ProviderLogoView(provider: provider, size: size)
            } else {
                monogram
            }
        }
    }

    private var monogram: some View {
        let initials = Self.monogramText(for: providerName, fallbackID: catalogProviderID)
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                .fill(DesignSystem.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
                )
            Text(initials)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(width: size, height: size)
    }

    /// Asset names worth probing for a given catalog provider ID. The real
    /// brand-mark PNGs that ship with the repo (`DeepSeekLogo`, `MistralLogo`,
    /// `MetaLogo`, `GrokLogo`, etc.) are preferred over the synthetic
    /// `*ProviderLogo` SVG placeholders that older builds used. The catalog's
    /// own registry is consulted as a tertiary fallback, and a conventional
    /// `{ID}Logo` lookup catches any future provider that ships an asset by
    /// name without needing a code change here.
    static func assetCandidates(for catalogProviderID: String) -> [String] {
        ProviderBrand.logoAssetCandidates(for: catalogProviderID)
    }

    static func monogramText(for providerName: String, fallbackID: String) -> String {
        let trimmedName = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedID = fallbackID.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmedName.isEmpty ? trimmedID : trimmedName
        guard !source.isEmpty else { return "?" }
        let parts = source
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        if let first = parts.first, parts.count == 1, let initial = first.first {
            return String(initial).uppercased()
        }
        let initials = parts.prefix(2).compactMap { $0.first }
        guard !initials.isEmpty else { return String(source.prefix(1)).uppercased() }
        return initials.map { String($0).uppercased() }.joined()
    }
}
