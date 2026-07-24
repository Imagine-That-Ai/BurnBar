import Foundation
import SwiftUI
import OpenBurnBarCore

/// Defines cross-platform layout destinations for the primary tabs and sidebar.
enum AppDestination: String, Hashable, Identifiable, Codable, CaseIterable {
    case pulse, burn, insights, calendar, streams, agents, you, settings, devices, providers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pulse:    return "Pulse"
        case .burn:     return "Burn"
        case .insights: return "Insights"
        case .calendar: return "Calendar"
        case .streams:  return "Streams"
        case .agents:   return "Agents"
        case .you:      return "You"
        case .settings: return "Settings"
        case .devices:  return "Devices"
        case .providers: return "Providers"
        }
    }

    var fallbackIcon: String {
        switch self {
        case .insights:  return "sparkles.tv.fill"
        case .calendar:  return "calendar"
        case .settings:  return "gearshape.fill"
        case .devices:   return "macbook.and.iphone"
        case .providers: return "externaldrive.connected.to.line.below"
        case .pulse:     return "waveform.path.ecg"
        case .burn:      return "flame.fill"
        case .streams:   return "list.bullet.rectangle.portrait.fill"
        case .agents:    return "theatermasks.fill"
        case .you:       return "person.crop.circle"
        }
    }

    var isPrimary: Bool {
        switch self {
        case .pulse, .burn, .insights, .calendar, .streams, .agents: return true
        default: return false
        }
    }

    var accent: Color {
        switch self {
        case .pulse:    return MobileTheme.ember
        case .burn:     return MobileTheme.amber
        case .insights: return MobileTheme.whimsy
        case .calendar: return MobileTheme.ember
        case .streams:  return MobileTheme.whimsy
        case .agents:   return MobileTheme.hermesAureate
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
        case .calendar: return .calendar
        case .streams:  return .streams
        case .agents:   return .hermes
        case .you:      return .you
        default:        return nil
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
    @AppStorage("appThemePalette") var themePalette: AppThemePalette = .system

    var primaryDestinations: [AppDestination] {
        get {
            if primaryTabsRaw.isEmpty { return [.pulse, .burn, .insights, .calendar, .streams, .agents] }
            guard let data = primaryTabsRaw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([AppDestination].self, from: data) else {
                return [.pulse, .burn, .insights, .calendar, .streams, .agents]
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                primaryTabsRaw = str
                objectWillChange.send()
            }
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

/// Durable restoration for the two mobile navigation shells.
///
/// SwiftUI preserves `@State` only while the process remains alive. iOS is
/// free to terminate a backgrounded app at any time, so navigation state must
/// be written outside the view tree if a relaunch is expected to resume where
/// the user left off.
enum MobileNavigationRestoration {
    enum PathKey: String, CaseIterable {
        case phonePulse = "mobile.navigation.phone.pulse.v1"
        case phoneBurn = "mobile.navigation.phone.burn.v1"
        case phoneCalendar = "mobile.navigation.phone.calendar.v1"
        case phoneStreams = "mobile.navigation.phone.streams.v1"
        case phoneHermes = "mobile.navigation.phone.hermes.v1"
        case phoneYou = "mobile.navigation.phone.you.v1"
        case padDetail = "mobile.navigation.pad.detail.v1"
    }

    private static let phoneSelectionKey = "mobile.navigation.phone.selection.v1"
    private static let padSelectionKey = "mobile.navigation.pad.selection.v1"

    static func phoneSelection(defaults: UserDefaults = .standard) -> AuroraNavDestination {
        defaults.string(forKey: phoneSelectionKey)
            .flatMap(AuroraNavDestination.init(rawValue:))
            ?? .pulse
    }

    static func savePhoneSelection(
        _ selection: AuroraNavDestination,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(selection.rawValue, forKey: phoneSelectionKey)
    }

    static func padSelection(defaults: UserDefaults = .standard) -> AppDestination {
        defaults.string(forKey: padSelectionKey)
            .flatMap(AppDestination.init(rawValue:))
            ?? .pulse
    }

    static func savePadSelection(
        _ selection: AppDestination,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(selection.rawValue, forKey: padSelectionKey)
    }

    static func path(
        for key: PathKey,
        defaults: UserDefaults = .standard
    ) -> NavigationPath {
        guard let data = defaults.data(forKey: key.rawValue),
              let representation = try? JSONDecoder().decode(
                  NavigationPath.CodableRepresentation.self,
                  from: data
              ) else {
            return NavigationPath()
        }
        return NavigationPath(representation)
    }

    static func save(
        _ path: NavigationPath,
        for key: PathKey,
        defaults: UserDefaults = .standard
    ) {
        guard let representation = path.codable,
              let data = try? JSONEncoder().encode(representation) else {
            // Never revive a stale route if a future destination is not
            // Codable. The selected root screen remains restorable.
            defaults.removeObject(forKey: key.rawValue)
            return
        }
        defaults.set(data, forKey: key.rawValue)
    }
}
