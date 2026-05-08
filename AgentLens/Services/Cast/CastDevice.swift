import Foundation

// MARK: - Cast Device
//
// Concrete representation of a Cast-capable device discovered on the LAN.
// We deduplicate on `serviceName` (the underlying mDNS instance name) and
// fall back to host:port for the equality contract.

public struct CastDevice: Hashable, Sendable, Codable {

    /// Stable mDNS service name, e.g. `Google-Nest-Hub-dec04a601c00269a3...`.
    /// We use this as the canonical identifier; it survives IP changes.
    public let serviceName: String

    /// Friendly name shown in the wizard UI ("Living Room Hub").
    public let friendlyName: String

    /// Last-known LAN IP. Refreshed whenever discovery picks the device up
    /// again — Cast devices frequently move between IPs on DHCP renewal.
    public var host: String

    /// Cast TLS port. Always 8009 in practice but the protocol allows
    /// device-side override, so we keep it flexible.
    public var port: Int

    /// Hardware model (`Google Nest Hub`, `Chromecast`, etc.) sourced from
    /// the `md` mDNS TXT record.
    public let model: String

    /// `id` field from the TXT record — UUID assigned by Google to the
    /// device at first setup; doubles as a human-stable ID.
    public let identifier: String

    public var lastSeenAt: Date

    /// Whether this device is likely to render web content. Audio-only
    /// devices (Nest Mini, Nest Audio, Google Home, Home Max) return
    /// `NOT_FOUND` when DashCast tries to launch on them. Set by
    /// `CastDiscovery` based on the Cast capability bitmask + model
    /// name heuristics. Defaults to `true` for safety — false positives
    /// here would silently hide a Nest Hub.
    public var supportsDisplay: Bool

    public init(
        serviceName: String,
        friendlyName: String,
        host: String,
        port: Int,
        model: String,
        identifier: String,
        lastSeenAt: Date = Date(),
        supportsDisplay: Bool = true
    ) {
        self.serviceName = serviceName
        self.friendlyName = friendlyName
        self.host = host
        self.port = port
        self.model = model
        self.identifier = identifier
        self.lastSeenAt = lastSeenAt
        self.supportsDisplay = supportsDisplay
    }

    /// Convenience for UI grouping — collapses `Google-Nest-Hub-Max-…` /
    /// `Chromecast-…` to icon-friendly buckets.
    public var iconKind: IconKind {
        let lower = model.lowercased()
        if lower.contains("nest hub max") { return .nestHubMax }
        if lower.contains("nest hub") { return .nestHub }
        if lower.contains("chromecast") { return .chromecast }
        if lower.contains("nest mini") || lower.contains("nest audio") { return .nestSpeaker }
        return .generic
    }

    public enum IconKind: String, Sendable, Codable {
        case nestHub
        case nestHubMax
        case chromecast
        case nestSpeaker
        case generic
    }
}
