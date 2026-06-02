import SwiftUI
import OpenBurnBarCore

// MARK: - Data Control Center theme bridge
//
// Binds the Pensieve design tokens (packages/design-tokens → PensieveTokens.swift,
// emitted as hex/rgba *strings*) to SwiftUI `Color` so the governance workbench
// stays in lock-step with the cross-platform palette instead of re-declaring
// colors. The tier colors (server-readable = amber, zero-access = steel,
// end-to-end = teal) come straight from the token file; everything else reuses
// the existing `DesignSystem` helpers so this pane matches the rest of macOS.
//
// All token strings are parsed once into static `Color` constants — no per-render
// scanning. `EncryptionTier` is the generated registry enum (gen/DataDomains.swift),
// so a new tier in the registry surfaces here via the exhaustive switch.

enum PensieveTheme {

    // MARK: Token → Color

    /// Parses a Pensieve token string. Supports `#rrggbb`, `#rrggbbaa`, and
    /// `rgba(r, g, b, a)` forms emitted by Style Dictionary. Falls back to the
    /// supplied `Color` when a token cannot be parsed (defensive — tokens are
    /// generated, but we never want a parse miss to paint pure black).
    static func color(_ token: String, fallback: Color) -> Color {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            return Color(hex: trimmed)
        }
        if trimmed.lowercased().hasPrefix("rgba"),
           let parsed = parseRGBA(trimmed) {
            return parsed
        }
        return fallback
    }

    private static func parseRGBA(_ token: String) -> Color? {
        guard let open = token.firstIndex(of: "("),
              let close = token.firstIndex(of: ")") else { return nil }
        let inner = token[token.index(after: open)..<close]
        let parts = inner
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let r = Double(parts[0]),
              let g = Double(parts[1]),
              let b = Double(parts[2]),
              let a = Double(parts[3]) else { return nil }
        return Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }

    // MARK: Tier palette (from PensieveTokens — colorTier*)

    static let serverReadable = color(PensieveTokens.colorTierServerReadable, fallback: DesignSystem.Colors.amber)
    static let zeroAccess     = color(PensieveTokens.colorTierZeroAccess,     fallback: DesignSystem.Colors.textMuted)
    static let endToEnd       = color(PensieveTokens.colorTierEndToEnd,       fallback: DesignSystem.Colors.teal)

    /// The single source of truth for a domain's tier accent. Every tier badge,
    /// chart tint, and inspector ring reads through here so the registry's
    /// `encryptionTier` is the only knob.
    static func tint(for tier: EncryptionTier) -> Color {
        switch tier {
        case .serverReadable: return serverReadable
        case .zeroAccess:     return zeroAccess
        case .endToEnd:       return endToEnd
        }
    }

    static func tierLabel(_ tier: EncryptionTier) -> String {
        switch tier {
        case .serverReadable: return "Server-readable"
        case .zeroAccess:     return "Zero-access"
        case .endToEnd:       return "End-to-end"
        }
    }

    static func tierIcon(_ tier: EncryptionTier) -> String {
        switch tier {
        case .serverReadable: return "eye.fill"
        case .zeroAccess:     return "lock.fill"
        case .endToEnd:       return "lock.shield.fill"
        }
    }

    /// One-line plain-language explanation of what the server can see at this
    /// tier — drives the inspector's "what we see" copy and the flip caption.
    static func tierExplanation(_ tier: EncryptionTier) -> String {
        switch tier {
        case .serverReadable:
            return "Stored as plaintext. BurnBar's servers can read this to run the product."
        case .zeroAccess:
            return "Encrypted at rest. BurnBar holds only the wrapped key under your device trust — it cannot read the content."
        case .endToEnd:
            return "Sealed on your device with the vault key. BurnBar never sees the plaintext or the key."
        }
    }

    // MARK: Mercury / basin substance (from PensieveTokens — colorMercury*)

    static let mercuryBright = color(PensieveTokens.colorMercuryBright, fallback: DesignSystem.Colors.hermesMercury)
    static let mercuryCore   = color(PensieveTokens.colorMercuryCore,   fallback: DesignSystem.Colors.hermesMercury)
    static let mercuryDeep   = color(PensieveTokens.colorMercuryDeep,   fallback: DesignSystem.Colors.textMuted)

    // MARK: Keys / CTA (from PensieveTokens — colorBrass*)

    static let brassCore   = color(PensieveTokens.colorBrassCore,   fallback: DesignSystem.Colors.ember)
    static let brassBright = color(PensieveTokens.colorBrassBright, fallback: DesignSystem.Colors.amber)

    /// Wax-crimson — destructive ONLY (panic, delete). Mapped from the seal
    /// crimson token, with the system error color as fallback.
    static let waxCrimson = color(PensieveTokens.colorSealCrimson, fallback: DesignSystem.Colors.error)
}

// MARK: - Settings search anchors (owned by this surface)
//
// Local anchor identifiers for the Data Control Center so the inventory is
// discoverable from the Settings search bar. The primary agent should mirror
// `inventory` into the canonical `SettingsAnchor` enum (SettingsItem.swift) and
// register a `SettingsItem` + `SettingsPageRoute.dataControlCenterRoot` in
// SettingsManifest so deep links resolve — see integrationNeeded.
enum DataControlCenterAnchors {
    static let inventory = "data.controlCenter.inventory"
}

// MARK: - Encryption tier display helpers on the generated enum

extension EncryptionTier {
    var tint: Color { PensieveTheme.tint(for: self) }
    var displayLabel: String { PensieveTheme.tierLabel(self) }
    var iconName: String { PensieveTheme.tierIcon(self) }
    var explanation: String { PensieveTheme.tierExplanation(self) }
}
