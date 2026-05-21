import Foundation

/// Per-device personalization. One value per `MercuryPeer.connectionID`,
/// stored inside a single `@AppStorage("mercury.personalization.v1")`
/// dictionary blob managed by `MercuryPersonalizationStore`.
///
/// Why all in one blob: each device has a small (<2KB) snapshot, and
/// `@AppStorage` plays well with a single `Data` value. Splitting per
/// key would multiply notification overhead with no real benefit.
struct MercuryDevicePersonalization: Codable, Equatable, Sendable {
    var nickname: String?
    var accent: MercuryAccent
    var avatar: MercuryAvatarStyle
    var background: MercuryBackgroundStyle
    var actionOrder: [MercuryQuickAction]
    var badges: [MercuryBadgeKind]
    var haptics: MercuryHapticsLevel
    var showHermesSquareTile: Bool
    var mimicLoginBackground: Bool
    var usePremiumSOTAUX: Bool?

    /// Settings used on the first appearance for any device that has no
    /// stored snapshot yet. Accent defaults to `.autoFromWallpaper` so
    /// users land on a color that matches their Mac's desktop without
    /// touching a single control.
    static let defaultForFirstRun = MercuryDevicePersonalization(
        nickname: nil,
        accent: .autoFromWallpaper,
        avatar: .laptop,
        background: .wallpaper,
        actionOrder: [.mirror, .call, .sendFile],
        badges: [.architecture, .os],
        haptics: .gentle,
        showHermesSquareTile: true,
        mimicLoginBackground: true,
        usePremiumSOTAUX: false
    )

    /// Returns a copy with `actionOrder` normalized: ordering preserved,
    /// duplicates removed. Hidden actions are not added back — visibility
    /// is intentional.
    func normalizedActionOrder() -> [MercuryQuickAction] {
        var seen: Set<MercuryQuickAction> = []
        return actionOrder.filter { seen.insert($0).inserted }
    }

    /// Returns up to two badges, padded with the defaults when the user
    /// has cleared them all.
    func normalizedBadges() -> [MercuryBadgeKind] {
        var seen: Set<MercuryBadgeKind> = []
        let normalized = badges.filter { seen.insert($0).inserted }
        if normalized.isEmpty { return [.architecture, .os] }
        return Array(normalized.prefix(2))
    }
}
