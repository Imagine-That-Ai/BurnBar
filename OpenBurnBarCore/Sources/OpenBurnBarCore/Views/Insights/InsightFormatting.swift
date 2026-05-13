import Foundation
import SwiftUI

/// Tiny formatting helpers used by every renderer.
public enum InsightFormatting {

    public static func format(_ value: Double, as format: ValueFormat) -> String {
        switch format {
        case .currency:
            if abs(value) >= 1000 {
                return String(format: "$%.0f", value)
            }
            if abs(value) >= 100 {
                return String(format: "$%.1f", value)
            }
            return String(format: "$%.2f", value)
        case .tokens:
            return tokensFormatter(value)
        case .percent:
            return String(format: "%.0f%%", value * 100)
        case .duration:
            if value < 60 {
                return String(format: "%.1fs", value)
            }
            if value < 3600 {
                return String(format: "%.0fm", value / 60)
            }
            return String(format: "%.1fh", value / 3600)
        case .count:
            return String(format: "%.0f", value)
        case .raw:
            return String(value)
        }
    }

    public static func formatDelta(_ delta: Double, asPercent: Bool) -> String {
        let prefix = delta >= 0 ? "+" : ""
        if asPercent {
            return "\(prefix)\(String(format: "%.0f%%", delta * 100))"
        }
        return "\(prefix)\(String(format: "%.2f", delta))"
    }

    public static func tokensFormatter(_ value: Double) -> String {
        if abs(value) >= 1_000_000_000 {
            return String(format: "%.1fB", value / 1_000_000_000)
        }
        if abs(value) >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if abs(value) >= 1_000 {
            return String(format: "%.1fk", value / 1_000)
        }
        return String(format: "%.0f", value)
    }

    public static func color(forHex hex: String?) -> Color? {
        guard let hex else { return nil }
        var trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard let value = UInt32(trimmed, radix: 16) else { return nil }
        let r, g, b: UInt32
        if trimmed.count == 6 {
            r = (value >> 16) & 0xff
            g = (value >> 8) & 0xff
            b = value & 0xff
        } else if trimmed.count == 8 {
            r = (value >> 16) & 0xff
            g = (value >> 8) & 0xff
            b = value & 0xff
        } else {
            return nil
        }
        return Color(.sRGB,
                     red: Double(r) / 255,
                     green: Double(g) / 255,
                     blue: Double(b) / 255,
                     opacity: 1)
    }

    public static func color(forSeriesID id: String, fallback: Color = UnifiedDesignSystem.Colors.ember) -> Color {
        // Stable color derived from the series id so the same series gets
        // the same color across renders.
        var hash: UInt64 = 5381
        for byte in id.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }

    public static func tone(_ tone: InsightWidgetData.Narrative.Tone) -> Color {
        switch tone {
        case .positive: return UnifiedDesignSystem.Colors.success
        case .neutral: return UnifiedDesignSystem.Colors.textSecondary
        case .warning: return UnifiedDesignSystem.Colors.warning
        case .negative: return UnifiedDesignSystem.Colors.error
        }
    }
}
