import Foundation
import SwiftUI
import OpenBurnBarKernel

// MARK: - App Skin

/// The app-wide visual *skin* — an axis orthogonal to light/dark appearance.
///
/// `aurora` is the original ember/glass look and stays the default. `editorial`
/// is the light-locked "Quiet Editorial" paper skin lifted from the
/// app.burnbar.ai console: paper surfaces, ink text, a single coral accent,
/// hairlines, and no glass/glow. Selecting it re-points the design-system color
/// tokens — every token-bound view flips coherently, exactly like the web
/// console re-points its CSS variables.
///
/// Persisted under ``storageKey`` in `UserDefaults.standard` so the token layer
/// (which has no SwiftUI context) can read the active skin while resolving a
/// dynamic `Color`. SwiftUI views read it via `@AppStorage(AppSkin.storageKey)`.
public enum AppSkin: String, CaseIterable, Codable, Sendable {
    case aurora
    case editorial

    /// `UserDefaults` / `@AppStorage` key. Shared verbatim across all platforms.
    public static let storageKey = "appSkin"

    /// The currently-selected skin, read live from `UserDefaults.standard`.
    /// Mirrors the lightweight pattern `MobileTheme.surface` already uses for
    /// the swarm flag so dynamic color providers can branch without a view.
    public static var current: AppSkin {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let skin = AppSkin(rawValue: raw) else { return .aurora }
        return skin
    }

    public var displayName: String {
        switch self {
        case .aurora:    return "Aurora"
        case .editorial: return "Editorial"
        }
    }
}

/// The named dashboard *layout* concept the macOS overview renders.
///
/// These are the five full-dashboard arrangements from the "Liquid Glass
/// Studio" design phase plus `classic` (the original information-dense scroll
/// overview, retained). Each concept floats glass cards over the shared
/// kernel + provider-swarm backdrop; `classic` keeps the legacy composition.
///
/// Shared across platforms (same `String` raw values + `storageKey`) so future
/// iOS/Android parity can read the same preference, mirroring `AppSkin`.
public enum DashboardLayout: String, CaseIterable, Codable, Sendable {
    /// The original macOS overview: a vertical scroll of stat cards, the live
    /// cost curve, the Great Hall, the narrative banner, and the provider /
    /// model / activity lanes. Information-dense; the safe fallback.
    case classic
    /// Provider list + open hero swarm field + a bottom data band.
    case aurora
    /// Bento grid: provider panel, a big burn card, a framed swarm stage, and
    /// a tokens / sessions / cost-curve row.
    case nebula
    /// Centered command column: a search/Hermes bar over a full swarm stage,
    /// three stat pills, and a wrap of provider chips.
    case constellation
    /// Mission-control grid: spend-share provider rail, four KPI tiles
    /// (incl. cache hit), a routing swarm stage with TPS, cost curve + The Wand.
    case cockpit
    /// The keeper: a full-bleed kernel-forward hero with a headline and three
    /// floating glass stat cards over the live substrate. The default.
    case atelier

    /// `UserDefaults` / `@AppStorage` key. Shared verbatim across platforms.
    public static let storageKey = "dashboardLayout"

    /// The currently-selected layout, read live from `UserDefaults.standard`.
    /// Defaults to ``atelier`` — the design phase's "keeper" — when unset.
    public static var current: DashboardLayout {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let layout = DashboardLayout(rawValue: raw) else { return .atelier }
        return layout
    }

    public var displayName: String {
        switch self {
        case .classic:       return "Classic"
        case .aurora:        return "Aurora"
        case .nebula:        return "Nebula"
        case .constellation: return "Constellation"
        case .cockpit:       return "Cockpit"
        case .atelier:       return "Atelier"
        }
    }

    /// SF Symbol used in pickers and the inline switcher.
    public var symbolName: String {
        switch self {
        case .classic:       return "rectangle.grid.1x2"
        case .aurora:        return "sun.haze"
        case .nebula:        return "rectangle.grid.2x2"
        case .constellation: return "sparkles"
        case .cockpit:       return "gauge.with.dots.needle.67percent"
        case .atelier:       return "paintpalette"
        }
    }

    /// Whether the concept is kernel-forward (full-bleed backdrop is the hero)
    /// versus a structured panel layout. Drives small-window fallbacks.
    public var isKernelForward: Bool {
        switch self {
        case .constellation, .atelier: return true
        case .classic, .aurora, .nebula, .cockpit: return false
        }
    }
}

// MARK: - Dashboard Launch Surface

/// Which screen the dashboard window opens on.
///
/// The route itself is deliberately **not** persisted — `DashboardMainRoute`
/// carries associated values so it is not `RawRepresentable`, the dashboard is
/// an AppKit `NSWindow` (so `@SceneStorage` is unavailable), and "restore last
/// route" would mean a user who ended yesterday in Session Logs never sees the
/// home again. This is the honest opt-out instead: a two-value preference.
///
/// Read through ``current`` from `UserDefaults.standard` rather than through
/// `SettingsManager`, mirroring ``DashboardLayout/current``, so a `@State`
/// initializer can consult it without depending on singleton init ordering.
public enum DashboardLaunchSurface: String, CaseIterable, Codable, Sendable {
    /// The AI Inbox with the live fleet + quota rail. The default.
    case home
    /// The legacy spend-first overview, rendered through the active
    /// ``DashboardLayout`` concept.
    case overview

    /// `UserDefaults` / `@AppStorage` key.
    public static let storageKey = "dashboardLaunchSurface"

    /// The currently-selected launch surface, read live from
    /// `UserDefaults.standard`. Defaults to ``home`` when unset.
    public static var current: DashboardLaunchSurface {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let surface = DashboardLaunchSurface(rawValue: raw) else { return .home }
        return surface
    }

    public var displayName: String {
        switch self {
        case .home:     return "Home"
        case .overview: return "Overview"
        }
    }

    public var symbolName: String {
        switch self {
        case .home:     return "house"
        case .overview: return "chart.bar.xaxis"
        }
    }

    public var explanation: String {
        switch self {
        case .home:     return "Opens on the inbox, with your fleet and quota beside it."
        case .overview: return "Opens on the spend overview in your chosen layout."
        }
    }
}

// MARK: - Hex Color Helpers

public extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    #if os(iOS)
    init(light: String, dark: String) {
        self.init(editorial: light, light: light, dark: dark)
    }

    /// Skin- and appearance-aware token color. When the editorial skin is
    /// active the `editorial` hex wins regardless of light/dark trait (the skin
    /// is light-locked); otherwise resolves `light`/`dark` off the trait.
    init(editorial: String, light: String, dark: String) {
        self.init(uiColor: UIColor(
            dynamicProvider: { traitCollection in
                if AppSkin.current == .editorial {
                    return UIColor(Color(hex: editorial))
                }
                let hex = traitCollection.userInterfaceStyle == .dark ? dark : light
                return UIColor(Color(hex: hex))
            }
        ))
    }
    #else
    init(light: String, dark: String) {
        self.init(editorial: light, light: light, dark: dark)
    }

    /// Skin- and appearance-aware token color. When the editorial skin is
    /// active the `editorial` hex wins regardless of aqua/dark appearance (the
    /// skin is light-locked); otherwise resolves `light`/`dark` off appearance.
    init(editorial: String, light: String, dark: String) {
        self.init(
            NSColor(name: nil) { appearance in
                if AppSkin.current == .editorial {
                    return NSColor(Color(hex: editorial))
                }
                let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(Color(hex: hex))
            }
        )
    }
    #endif
}

// MARK: - Design System SwiftUI Colors
//
// The raw hex `DesignSystemTokens` and the Foundation `DesignSystemColors`
// surface (`providerRGBA(_:)`) now live in `DesignSystemTokens.swift`. This
// file keeps the SwiftUI `Color`-returning accessors as an extension, so the
// type's Color surface stays here while its Foundation surface compiles without
// SwiftUI. On Apple platforms the public API is identical to before the split.

extension DesignSystemColors {
    public static let ember   = Color(editorial: DesignSystemTokens.emberEditorial, light: DesignSystemTokens.emberLight, dark: DesignSystemTokens.emberDark)
    public static let amber   = Color(editorial: DesignSystemTokens.amberEditorial, light: DesignSystemTokens.amberLight, dark: DesignSystemTokens.amberDark)
    public static let blaze   = Color(editorial: DesignSystemTokens.blazeEditorial, light: DesignSystemTokens.blazeLight, dark: DesignSystemTokens.blazeDark)
    public static let whimsy  = Color(editorial: DesignSystemTokens.whimsyEditorial, light: DesignSystemTokens.whimsyLight, dark: DesignSystemTokens.whimsyDark)

    public static let background      = Color(editorial: DesignSystemTokens.backgroundEditorial, light: DesignSystemTokens.backgroundLight, dark: DesignSystemTokens.backgroundDark)
    public static let surface         = Color(editorial: DesignSystemTokens.surfaceEditorial, light: DesignSystemTokens.surfaceLight, dark: DesignSystemTokens.surfaceDark)
    public static let surfaceElevated = Color(editorial: DesignSystemTokens.surfaceElevatedEditorial, light: DesignSystemTokens.surfaceElevatedLight, dark: DesignSystemTokens.surfaceElevatedDark)
    public static let border          = Color(editorial: DesignSystemTokens.borderEditorial, light: DesignSystemTokens.borderLight, dark: DesignSystemTokens.borderDark)
    public static let borderSubtle    = Color(editorial: DesignSystemTokens.borderSubtleEditorial, light: DesignSystemTokens.borderSubtleLight, dark: DesignSystemTokens.borderSubtleDark)

    public static let textPrimary   = Color(editorial: DesignSystemTokens.textPrimaryEditorial, light: DesignSystemTokens.textPrimaryLight, dark: DesignSystemTokens.textPrimaryDark)
    public static let textSecondary = Color(editorial: DesignSystemTokens.textSecondaryEditorial, light: DesignSystemTokens.textSecondaryLight, dark: DesignSystemTokens.textSecondaryDark)
    public static let textMuted     = Color(editorial: DesignSystemTokens.textMutedEditorial, light: DesignSystemTokens.textMutedLight, dark: DesignSystemTokens.textMutedDark)

    public static let success = Color(editorial: DesignSystemTokens.successEditorial, light: DesignSystemTokens.successLight, dark: DesignSystemTokens.successDark)
    public static let warning = Color(editorial: DesignSystemTokens.warningEditorial, light: DesignSystemTokens.warningLight, dark: DesignSystemTokens.warningDark)
    public static let error   = Color(editorial: DesignSystemTokens.errorEditorial, light: DesignSystemTokens.errorLight, dark: DesignSystemTokens.errorDark)

    public static func primary(for provider: AgentProvider) -> Color {
        switch provider {
        case .factory:    return Color(hex: "8B5CF6")
        case .claudeCode: return Color(hex: "CC785C")
        case .copilot:    return Color(hex: "23EA3B")
        case .aider:      return Color(hex: "FF6B35")
        case .cursor:     return Color(hex: "B4B8C0")
        case .openAI:     return Color(hex: "00A67E")
        case .deepSeek:   return Color(hex: "6366F1")
        case .codex:      return Color(hex: "2563EB")
        case .zai:        return Color(hex: "8B5CF6")
        case .minimax:    return Color(hex: "F59E0B")
        case .kimi:       return Color(hex: "6366F1")
        case .cline:      return Color(hex: "D4A373")
        case .kiloCode:   return Color(hex: "10B981")
        case .rooCode:    return Color(hex: "EC4899")
        case .forgeDev:   return Color(hex: "F97316")
        case .augment:    return Color(hex: "3B82F6")
        case .hermes:     return Color(hex: "A855F7")
        case .piAgent:    return Color(hex: "7C3AED")
        case .geminiCLI:  return Color(hex: "4285F4")
        case .antigravity: return Color(hex: "6C63FF")
        case .cursorAgent: return Color(hex: "00E5FF")
        case .goose:      return Color(hex: "0D9488")
        case .openClaw: return Color(hex: "FF6B6B")
        case .openClaude: return Color(hex: "D97757")
        case .omp: return Color(hex: "EC4899")
        case .ollama:     return Color(hex: "6B7280")
        case .windsurf:   return Color(hex: "06B6D4")
        case .devin:      return Color(hex: "0A84FF")
        case .warp:       return Color(hex: "DDE4EA")
        case .openCode:   return Color(hex: "2563EB")
        case .xAI:        return Color(hex: "1A1A1A")
        case .mimo:       return Color(hex: "FF6900")
        case .primeAgent: return Color(hex: "582CFF")
        case .muse: return Color(hex: "0668E1")
        case .openBurnBar: return Color(hex: "FA5053")
        case .junie:      return Color(hex: "48E054")
        }
    }

    public static func accent(for provider: AgentProvider) -> Color {
        switch provider {
        case .factory:    return ember
        case .claudeCode: return Color(hex: "D4A574")
        case .copilot:    return Color(hex: "0969DA")
        case .aider:      return blaze
        case .cursor:     return Color(hex: "1A1A1A")
        case .openAI:     return Color(hex: "00C48C")
        case .deepSeek:   return Color(hex: "818CF8")
        case .codex:      return Color(hex: "60A5FA")
        case .zai:        return Color(hex: "A78BFA")
        case .minimax:    return Color(hex: "FCD34D")
        case .kimi:       return Color(hex: "818CF8")
        case .cline:      return Color(hex: "E8C4A0")
        case .kiloCode:   return Color(hex: "34D399")
        case .rooCode:    return Color(hex: "F472B6")
        case .forgeDev:   return Color(hex: "FB923C")
        case .augment:    return Color(hex: "60A5FA")
        case .hermes:     return Color(hex: "C084FC")
        case .piAgent:    return Color(hex: "A78BFA")
        case .geminiCLI:  return Color(hex: "8AB4F8")
        case .antigravity: return Color(hex: "8F8AFF")
        case .cursorAgent: return Color(hex: "33ECFF")
        case .goose:      return Color(hex: "2DD4BF")
        case .openClaw: return Color(hex: "F472B6")
        case .openClaude: return Color(hex: "E8855F")
        case .omp: return Color(hex: "F472B6")
        case .ollama:     return Color(hex: "9CA3AF")
        case .windsurf:   return Color(hex: "22D3EE")
        case .devin:      return Color(hex: "1E293B")
        case .warp:       return Color(hex: "111111")
        case .openCode:   return Color(hex: "93C5FD")
        case .xAI:        return Color(hex: "4A4A4A")
        case .mimo:       return Color(hex: "FF8533")
        case .primeAgent: return Color(hex: "7C5CFF")
        case .muse: return Color(hex: "3B82F6")
        case .openBurnBar: return Color(hex: "FF7578")
        case .junie:      return Color(hex: "6FE87F")
        }
    }
    public static func colorForModel(_ modelName: String) -> Color {
        let key = modelName.lowercased()

        // Known brand colors — deterministic, human-meaningful mapping.
        if key.contains("claude") || key.contains("anthropic") {
            return Color(hex: "CC785C")
        }
        if key.contains("gpt") || key.contains("openai") || key.contains("chatgpt") {
            return Color(hex: "00A67E")
        }
        if key.contains("gemini") || key.contains("google") {
            return Color(hex: "4285F4")
        }
        if key.contains("deepseek") {
            return Color(hex: "6366F1")
        }
        if key.contains("kimi") || key.contains("moonshot") {
            return Color(hex: "6366F1")
        }
        if key.contains("minimax") || key.contains("abab") {
            return Color(hex: "F59E0B")
        }
        if key.contains("llama") || key.contains("meta") {
            return Color(hex: "0668E1")
        }
        if key.contains("mistral") || key.contains("mixtral") {
            return Color(hex: "FF7000")
        }
        if key.contains("qwen") || key.contains("qwq") {
            return Color(hex: "615EFF")
        }
        if key.contains("grok") || key.contains("xai") {
            return Color(hex: "1A1A1A")
        }
        if key.contains("cohere") || key.contains("command") {
            return Color(hex: "39594D")
        }
        if key.contains("perplexity") || key.contains("sonar") {
            return Color(hex: "20808D")
        }
        if key.contains("mlx") || key.contains("apple") {
            return Color(hex: "A2AAAD")
        }
        if key.contains("nova") || key.contains("amazon") || key.contains("bedrock") {
            return Color(hex: "FF9900")
        }
        if key.contains("alibaba") || key.contains("tongyi") {
            return Color(hex: "FF6A00")
        }
        if key.contains("ollama") {
            return Color(hex: "8B8589")
        }

        // Deterministic fallback palette for unknown models.
        let palette: [Color] = [
            Color(hex: "D4A373"), Color(hex: "10B981"), Color(hex: "EC4899"),
            Color(hex: "F97316"), Color(hex: "3B82F6"), Color(hex: "A855F7"),
            Color(hex: "EF4444"), Color(hex: "14B8A6"), Color(hex: "F59E0B"),
            Color(hex: "8B5CF6"), Color(hex: "06B6D4"), Color(hex: "84CC16")
        ]
        var hash = UInt64(5381)
        for byte in key.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
