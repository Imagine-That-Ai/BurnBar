import Foundation

/// Information chips that can appear under the device name in
/// `MercuryHeaderCard`. The user picks two; the picker enforces the
/// two-chip cap. Some kinds depend on data we don't have yet
/// (battery, hostname, ip, app) — when the value resolver returns nil
/// the badge is silently swapped for the next available default kind.
enum MercuryBadgeKind: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case architecture
    case os
    case battery
    case lastSeen
    case hostname
    case ip
    case app

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .architecture: return "Architecture"
        case .os:           return "OS"
        case .battery:      return "Battery"
        case .lastSeen:     return "Last seen"
        case .hostname:     return "Hostname"
        case .ip:           return "IP"
        case .app:          return "Foreground app"
        }
    }

    var icon: String {
        switch self {
        case .architecture: return "cpu"
        case .os:           return "macwindow"
        case .battery:      return "battery.75percent"
        case .lastSeen:     return "clock"
        case .hostname:     return "tag.fill"
        case .ip:           return "network"
        case .app:          return "app.dashed"
        }
    }

    /// Kinds we can currently resolve from `MercuryPeer`. Others render
    /// a placeholder ("—") until upstream wiring lands.
    var isCurrentlyResolvable: Bool {
        switch self {
        case .architecture, .os, .lastSeen: return true
        case .battery, .hostname, .ip, .app: return false
        }
    }
}
