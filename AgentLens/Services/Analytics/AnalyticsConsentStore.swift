import Combine
import Foundation

/// Tri-state analytics consent — the spine of the opt-in analytics system.
///
/// Default is `.unset`: nothing initializes Amplitude and no event leaves the
/// device until the user affirmatively grants. `.declined` and `.unset` are
/// treated identically by the gate (`isGranted == false`). `revoke()` lands in
/// `.declined`, which stops all future sends — nothing is flushed.
///
/// Modeled on `MercuryConsentStore`: a tiny `UserDefaults`-backed, `@MainActor`
/// `ObservableObject` that persists on every change. The settings toggle and the
/// first-run opt-in prompt drive `grant()` / `decline()` / `revoke()`, and the
/// Amplitude wrapper reads `isGranted` on every call.
enum AnalyticsConsent: String, Sendable {
    case unset
    case granted
    case declined
}

@MainActor
final class AnalyticsConsentStore: ObservableObject {
    static let key = "analyticsConsentState"

    @Published private(set) var consent: AnalyticsConsent {
        didSet { defaults.set(consent.rawValue, forKey: Self.key) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Self.key)
        self.consent = raw.flatMap(AnalyticsConsent.init(rawValue:)) ?? .unset
    }

    /// The single check the Amplitude wrapper reads on every call.
    var isGranted: Bool { consent == .granted }

    /// Whether the user has answered the opt-in prompt yet (drives first-run UI).
    var hasDecided: Bool { consent != .unset }

    func grant() { consent = .granted }
    func decline() { consent = .declined }
    /// Revoke = decline. Stops all future sends; flushes nothing.
    func revoke() { consent = .declined }
}
