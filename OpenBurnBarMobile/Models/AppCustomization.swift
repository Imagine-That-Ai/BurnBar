import Foundation
import SwiftUI
import OpenBurnBarCore

/// Defines cross-platform layout destinations for the primary tabs and sidebar.
enum AppDestination: String, Hashable, Identifiable, Codable, CaseIterable {
    case pulse, burn, insights, streams, agents, inbox, fleet, you, settings, devices, providers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pulse:    return "Pulse"
        case .burn:     return "Burn"
        case .insights: return "Insights"
        case .streams:  return "Streams"
        case .agents:   return "Agents"
        case .inbox:    return "AI Inbox"
        case .fleet:    return "Fleet"
        case .you:      return "You"
        case .settings: return "Settings"
        case .devices:  return "Devices"
        case .providers: return "Providers"
        }
    }

    var fallbackIcon: String {
        switch self {
        case .insights:  return "sparkles.tv.fill"
        case .settings:  return "gearshape.fill"
        case .devices:   return "macbook.and.iphone"
        case .providers: return "externaldrive.connected.to.line.below"
        case .pulse:     return "waveform.path.ecg"
        case .burn:      return "flame.fill"
        case .streams:   return "list.bullet.rectangle.portrait.fill"
        case .agents:    return "theatermasks.fill"
        case .inbox:     return "tray.full.fill"
        case .fleet:     return "point.3.connected.trianglepath.dotted"
        case .you:       return "person.crop.circle"
        }
    }

    var isPrimary: Bool {
        switch self {
        case .pulse, .burn, .insights, .streams, .agents, .inbox, .fleet: return true
        default: return false
        }
    }

    var accent: Color {
        switch self {
        case .pulse:    return MobileTheme.ember
        case .burn:     return MobileTheme.amber
        case .insights: return MobileTheme.whimsy
        case .streams:  return MobileTheme.whimsy
        case .agents:   return MobileTheme.hermesAureate
        case .inbox:    return MobileTheme.amber
        case .fleet:    return MobileTheme.success
        case .you:      return MobileTheme.blaze
        case .settings: return MobileTheme.amber
        case .devices:  return MobileTheme.whimsy
        case .providers: return MobileTheme.ember
        }
    }

    var asAuroraDestination: AuroraNavDestination? {
        switch self {
        case .pulse:    return .pulse
        case .burn:     return .burn
        case .insights: return .insights
        case .streams:  return .streams
        case .agents:   return .hermes
        case .inbox:    return .inbox
        case .fleet:    return .fleet
        case .you:      return .you
        default:        return nil
        }
    }

    var auroraAccessibilityIdentifier: String {
        "auroraTab.\(asAuroraDestination?.id ?? id)"
    }
}

extension AuroraNavDestination {
    /// Inverse of `AppDestination.asAuroraDestination` — every tray kind has a
    /// sidebar counterpart (the sidebar-only kinds settings/devices/providers
    /// simply have no tray form).
    var asAppDestination: AppDestination {
        switch self {
        case .pulse:    return .pulse
        case .burn:     return .burn
        case .insights: return .insights
        case .streams:  return .streams
        case .hermes:   return .agents
        case .inbox:    return .inbox
        case .fleet:    return .fleet
        case .you:      return .you
        }
    }
}

/// Provides shared color palettes for matching Mac OS themes across platforms.
enum AppThemePalette: String, CaseIterable, Identifiable, Codable {
    case system = "System"
    case auroraTeal = "Aurora"
    case crimson = "Crimson"
    case cyberpunkViolet = "Cyberpunk"
    case forestMoss = "Moss"
    case solarFlare = "Solar"

    var id: String { rawValue }

    var tintColor: Color? {
        switch self {
        case .system: return nil
        case .auroraTeal: return Color(red: 0.1, green: 0.7, blue: 0.6)
        case .crimson: return Color(red: 0.8, green: 0.1, blue: 0.2)
        case .cyberpunkViolet: return Color(red: 0.7, green: 0.2, blue: 0.9)
        case .forestMoss: return Color(red: 0.2, green: 0.6, blue: 0.3)
        case .solarFlare: return Color(red: 0.9, green: 0.5, blue: 0.1)
        }
    }

    var swarmPalette: SwarmColorPalette {
        switch self {
        case .system: return .defaultEmber
        case .auroraTeal: return .auroraTeal
        case .crimson: return .sunsetCrimson
        case .cyberpunkViolet: return .cyberpunkViolet
        case .forestMoss: return .forestMoss
        case .solarFlare: return .solarFlare
        }
    }

    var backdropColors: [Color]? {
        switch self {
        case .system:
            return nil
        case .auroraTeal:
            return [
                Color(red: 0.015, green: 0.045, blue: 0.050),
                Color(red: 0.050, green: 0.180, blue: 0.200),
                Color(red: 0.120, green: 0.380, blue: 0.400)
            ]
        case .crimson:
            return [
                Color(red: 0.045, green: 0.018, blue: 0.020),
                Color(red: 0.180, green: 0.055, blue: 0.070),
                Color(red: 0.420, green: 0.115, blue: 0.145)
            ]
        case .cyberpunkViolet:
            return [
                Color(red: 0.030, green: 0.015, blue: 0.045),
                Color(red: 0.150, green: 0.055, blue: 0.220),
                Color(red: 0.380, green: 0.120, blue: 0.520)
            ]
        case .forestMoss:
            return [
                Color(red: 0.015, green: 0.035, blue: 0.020),
                Color(red: 0.055, green: 0.140, blue: 0.080),
                Color(red: 0.150, green: 0.320, blue: 0.180)
            ]
        case .solarFlare:
            return [
                Color(red: 0.050, green: 0.035, blue: 0.015),
                Color(red: 0.200, green: 0.140, blue: 0.055),
                Color(red: 0.480, green: 0.340, blue: 0.120)
            ]
        }
    }
}

@MainActor
final class AppCustomization: ObservableObject {
    static let shared = AppCustomization()

    @AppStorage("customPrimaryTabs") private var primaryTabsRaw: String = ""
    @AppStorage("customSecondaryTabs") private var secondaryTabsRaw: String = ""
    @AppStorage("customNavItems") private var navItemsRaw: String = ""
    @AppStorage("rootSwipeNavigationEnabled") var isSwipeNavigationEnabled: Bool = true
    @AppStorage("appThemePalette") var themePalette: AppThemePalette = .system

    /// The user's tab bar, in order. This is the single source of truth for
    /// the iPhone tray; the iPad sidebar derives its primary section from it
    /// (deduped by kind — instances are a tray concept).
    ///
    /// First read migrates the legacy iPad-only `customPrimaryTabs` order so a
    /// user who had rearranged the sidebar keeps that order in the tray.
    var navItems: [AuroraNavItem] {
        get {
            if navItemsRaw.isEmpty {
                return Self.migratedNavItems(fromLegacyPrimaryRaw: primaryTabsRaw)
            }
            return Self.decodeNavItems(fromRaw: navItemsRaw) ?? AuroraNavItem.defaultItems
        }
        set {
            let sanitized = AuroraNavItem.sanitized(newValue)
            if let data = try? JSONEncoder().encode(sanitized), // try?-ok(unencodable layout keeps the previous persisted one)
               let str = String(data: data, encoding: .utf8) {
                navItemsRaw = str
                objectWillChange.send()
            }
        }
    }

    /// Decodes a persisted layout, sanitized. `nil` for empty or corrupt raw
    /// strings (the caller decides the fallback — defaults vs migration).
    nonisolated static func decodeNavItems(fromRaw raw: String) -> [AuroraNavItem]? {
        guard raw.isEmpty == false,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AuroraNavItem].self, from: data) else { // try?-ok(corrupt persisted layout falls back to defaults)
            return nil
        }
        return AuroraNavItem.sanitized(decoded)
    }

    /// Legacy sidebar order → tray layout. `customPrimaryTabs` never contained
    /// `.you` (it lived in the secondary section); `sanitized` re-appends it so
    /// Settings stays reachable.
    nonisolated static func migratedNavItems(fromLegacyPrimaryRaw raw: String) -> [AuroraNavItem] {
        guard raw.isEmpty == false,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AppDestination].self, from: data), // try?-ok(unreadable legacy order falls back to defaults)
              decoded.isEmpty == false else {
            return AuroraNavItem.defaultItems
        }
        let items = decoded.compactMap { destination in
            destination.asAuroraDestination.map { AuroraNavItem.canonical($0) }
        }
        return AuroraNavItem.sanitized(items)
    }

    var primaryDestinations: [AppDestination] {
        get {
            // `.you` is excluded: the iPad sidebar renders it in the Account
            // (secondary) section, and the historic primary list never held it.
            var seen = Set<AppDestination>()
            return navItems.compactMap { item in
                let destination = item.kind.asAppDestination
                guard destination != .you else { return nil }
                return seen.insert(destination).inserted ? destination : nil
            }
        }
        set {
            // Legacy write path (iPad sidebar reorder): apply the new kind
            // order to the nav items, keeping instance configuration.
            let order = newValue.compactMap(\.asAuroraDestination)
            var remaining = navItems
            var reordered: [AuroraNavItem] = []
            for kind in order {
                while let index = remaining.firstIndex(where: { $0.kind == kind }) {
                    reordered.append(remaining.remove(at: index))
                }
            }
            navItems = reordered + remaining
        }
    }

    var secondaryDestinations: [AppDestination] {
        get {
            if secondaryTabsRaw.isEmpty { return [.you, .providers, .devices, .settings] }
            guard let data = secondaryTabsRaw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([AppDestination].self, from: data) else {
                return [.you, .providers, .devices, .settings]
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                secondaryTabsRaw = str
                objectWillChange.send()
            }
        }
    }
}
