import SwiftUI
import OpenBurnBarCore

// MARK: - Encryption-tier styling
//
// Binds the data-domain registry's `EncryptionTier` to the canonical Pensieve
// design tokens (no hardcoded colors): server_readable = brass/amber,
// zero_access = mercury steel, end_to_end = teal. Sourced from
// `PensieveTokens.colorTier*` so the iOS surface never drifts from web/Android.

extension EncryptionTier {
    /// Tier accent color from the generated Pensieve tokens.
    var tierColor: Color {
        switch self {
        case .serverReadable: return Color(hex: PensieveTokens.colorTierServerReadable)
        case .zeroAccess:     return Color(hex: PensieveTokens.colorTierZeroAccess)
        case .endToEnd:       return Color(hex: PensieveTokens.colorTierEndToEnd)
        }
    }

    var shortLabel: String {
        switch self {
        case .serverReadable: return "Server-readable"
        case .zeroAccess:     return "Zero-access"
        case .endToEnd:       return "End-to-end"
        }
    }

    /// One-line plain-language promise the inventory row surfaces.
    var promise: String {
        switch self {
        case .serverReadable:
            return "Stored so the cockpit can show it — metadata only, never your prompts."
        case .zeroAccess:
            return "Sealed envelopes only. The server holds ciphertext it can't open."
        case .endToEnd:
            return "Encrypted on this device. Decrypted only on devices you trust."
        }
    }

    var lockSymbol: String {
        switch self {
        case .serverReadable: return "eye"
        case .zeroAccess:     return "lock.shield"
        case .endToEnd:       return "lock.laptopcomputer"
        }
    }
}

// MARK: - Byte / count formatting

enum DataVaultFormat {
    static func bytes(_ value: Int) -> String {
        guard value > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(value)
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        return unit == 0 ? "\(Int(size)) \(units[unit])" : String(format: "%.1f %@", size, units[unit])
    }

    static func count(_ value: Int, noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}
