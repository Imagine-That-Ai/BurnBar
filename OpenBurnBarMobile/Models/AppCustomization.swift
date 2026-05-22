import Foundation
import SwiftUI
import OpenBurnBarCore

/// Defines cross-platform layout destinations for the primary tabs and sidebar.
public enum AppDestination: String, Hashable, Identifiable, Codable, CaseIterable {
    case pulse, burn, insights, streams, agents, you, settings, devices, providers

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .pulse:    return "Pulse"
        case .burn:     return "Burn"
        case .insights: return "Insights"
        case .streams:  return "Streams"
        case .agents:   return "Agents"
        case .you:      return "You"
        case .settings: return "Settings"
        case .devices:  return "Devices"
        case .providers: return "Providers"
        }
    }

    public var fallbackIcon: String {
        switch self {
        case .insights:  return "sparkles.tv.fill"
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

    public var isPrimary: Bool {
        switch self {
        case .pulse, .burn, .insights, .streams, .agents: return true
        default: return false
        }
    }

    public var accent: Color {
        switch self {
        case .pulse:    return MobileTheme.ember
        case .burn:     return MobileTheme.amber
        case .insights: return MobileTheme.whimsy
        case .streams:  return MobileTheme.whimsy
        case .agents:   return MobileTheme.hermesAureate
        case .you:      return MobileTheme.blaze
        case .settings: return MobileTheme.amber
        case .devices:  return MobileTheme.whimsy
        case .providers: return MobileTheme.ember
        }
    }

    public var asAuroraDestination: AuroraNavDestination? {
        switch self {
        case .pulse:    return .pulse
        case .burn:     return .burn
        case .insights: return .insights
        case .streams:  return .streams
        case .agents:   return .hermes
        case .you:      return .you
        default:        return nil
        }
    }
}

/// Provides shared color palettes for matching Mac OS themes across platforms.
public enum AppThemePalette: String, CaseIterable, Identifiable, Codable {
    case system = "System"
    case auroraTeal = "Aurora"
    case crimson = "Crimson"
    case cyberpunkViolet = "Cyberpunk"
    case forestMoss = "Moss"
    case solarFlare = "Solar"

    public var id: String { rawValue }

    public var tintColor: Color? {
        switch self {
        case .system: return nil
        case .auroraTeal: return Color(red: 0.1, green: 0.7, blue: 0.6)
        case .crimson: return Color(red: 0.8, green: 0.1, blue: 0.2)
        case .cyberpunkViolet: return Color(red: 0.7, green: 0.2, blue: 0.9)
        case .forestMoss: return Color(red: 0.2, green: 0.6, blue: 0.3)
        case .solarFlare: return Color(red: 0.9, green: 0.5, blue: 0.1)
        }
    }

    public var swarmPalette: SwarmColorPalette {
        switch self {
        case .system: return .auroraTeal
        case .auroraTeal: return .auroraTeal
        case .crimson: return .cyberpunkViolet // Temporary fallback
        case .cyberpunkViolet: return .cyberpunkViolet
        case .forestMoss: return .forestMoss
        case .solarFlare: return .solarFlare
        }
    }
}

public class AppCustomization: ObservableObject {
    public static let shared = AppCustomization()

    @AppStorage("customPrimaryTabs") private var primaryTabsRaw: String = ""
    @AppStorage("customSecondaryTabs") private var secondaryTabsRaw: String = ""
    @AppStorage("appThemePalette") public var themePalette: AppThemePalette = .system

    public var primaryDestinations: [AppDestination] {
        get {
            if primaryTabsRaw.isEmpty { return [.pulse, .burn, .insights, .streams, .agents] }
            guard let data = primaryTabsRaw.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([AppDestination].self, from: data) else {
                return [.pulse, .burn, .insights, .streams, .agents]
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

    public var secondaryDestinations: [AppDestination] {
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
