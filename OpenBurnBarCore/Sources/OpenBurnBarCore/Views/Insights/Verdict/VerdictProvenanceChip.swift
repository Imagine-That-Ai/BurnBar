import SwiftUI

/// Small pill rendered under the verdict hero showing who authored the
/// verdict ("Authored locally by qwen3-coder:30b · 1.4s · 0 tokens out").
///
/// Voice contract §3.3 — provenance is always shown. The chip's tint
/// shifts subtly based on the egress tier so the user can see at a
/// glance whether the verdict was authored on-device or via a hosted
/// model — without reading the words.
public struct VerdictProvenanceChip: View {

    public var provenance: InsightModelTag
    public var latencyLabel: String?
    public var tokensLabel: String?
    public var isFallback: Bool

    public init(
        provenance: InsightModelTag,
        latencyLabel: String? = nil,
        tokensLabel: String? = nil,
        isFallback: Bool = false
    ) {
        self.provenance = provenance
        self.latencyLabel = latencyLabel
        self.tokensLabel = tokensLabel
        self.isFallback = isFallback
    }

    public var body: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
            Image(systemName: provenance.egressTier.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(displayText)
                .font(UnifiedDesignSystem.Typography.monoTiny)
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
        .padding(.vertical, UnifiedDesignSystem.Spacing.xs)
        .background(
            Capsule()
                .fill(tint.opacity(0.08))
                .overlay(
                    Capsule().stroke(tint.opacity(0.3), lineWidth: 0.5)
                )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var displayText: String {
        var parts: [String] = []
        if isFallback {
            parts.append("Fallback")
        }
        if provenance.providerKey == "local-rules" {
            parts.append("Authored locally · Rule engine")
        } else if provenance.providerKey == "burnbar-demo" {
            parts.append("Demo verdict")
        } else {
            parts.append("Authored by \(provenance.displayName)")
        }
        if let latencyLabel { parts.append(latencyLabel) }
        if let tokensLabel { parts.append(tokensLabel) }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts: [String] = ["Authored by \(provenance.displayName)."]
        parts.append("Egress tier: \(provenance.egressTier.displayLabel).")
        if let latencyLabel { parts.append("Took \(latencyLabel).") }
        if let tokensLabel { parts.append("Output \(tokensLabel).") }
        if isFallback { parts.append("Hosted fallback path.") }
        return parts.joined(separator: " ")
    }

    private var tint: Color {
        switch provenance.egressTier {
        case .localOnly: return UnifiedDesignSystem.Colors.hermesMercury
        case .userKey: return UnifiedDesignSystem.Colors.ember
        case .userRelay: return UnifiedDesignSystem.Colors.whimsy
        case .hosted: return UnifiedDesignSystem.Colors.warning
        }
    }
}
