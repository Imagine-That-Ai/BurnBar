import Foundation
#if canImport(Combine)
import Combine
#endif

/// Tri-state analytics consent — the spine of the opt-in analytics system,
/// ported from `AgentLens/Services/Analytics/AnalyticsConsentStore.swift`.
///
/// Default is `.unset`: nothing initializes Amplitude and no event leaves the
/// device until the user affirmatively grants. `.declined` and `.unset` are
/// treated identically by the gate (`isGranted == false`). `revoke()` lands in
/// `.declined`, which stops all future sends — nothing is flushed.
///
/// **iOS divergence from macOS:** consent is persisted in the **shared App
/// Group** (`group.com.openburnbar.app`) rather than `.standard`, so the
/// WidgetKit and keyboard extensions — which run in separate processes — can
/// read the host app's decision and stay dark unless the host granted. Only the
/// host app mutates this; the extensions read it through
/// `AnalyticsConsentReader` and never write.
public enum AnalyticsConsent: String, Sendable {
    case unset
    case granted
    case declined
}

/// Process-wide, nonisolated coordinates for the shared consent record. Kept off
/// the `@MainActor` store so the (nonisolated) extension reader and the device-id
/// helper can reference them without crossing an actor boundary. These are plain
/// constants, not mutable state, so they are safe to read from any isolation.
public enum AnalyticsConsentStorage {
    /// The App Group the host app and its extensions share. Matches the existing
    /// `TextExpansionSnapshotStore.appGroupIdentifier` / widget-snapshot group so
    /// there is exactly one shared suite across the trio.
    public static let appGroupIdentifier = "group.com.openburnbar.app"
    public static let key = "analyticsConsentState"
}

@MainActor
public final class AnalyticsConsentStore {
    /// Convenience re-exports of the shared storage coordinates (kept here so call
    /// sites that already say `AnalyticsConsentStore.appGroupIdentifier` keep working).
    public static let appGroupIdentifier = AnalyticsConsentStorage.appGroupIdentifier
    public static let key = AnalyticsConsentStorage.key

    #if canImport(Combine)
    @Published public private(set) var consent: AnalyticsConsent {
        didSet { defaults.set(consent.rawValue, forKey: Self.key) }
    }
    #else
    public private(set) var consent: AnalyticsConsent {
        didSet { defaults.set(consent.rawValue, forKey: Self.key) }
    }
    #endif

    private let defaults: UserDefaults

    /// Defaults to the shared App Group suite so the extensions can read the same
    /// value. Falls back to `.standard` only if the App Group container is
    /// unavailable (e.g. unsigned unit-test host) — keeping the host functional
    /// while the extensions simply observe `unset` and stay dark.
    public init(defaults: UserDefaults? = nil) {
        let resolved = defaults
            ?? UserDefaults(suiteName: AnalyticsConsentStorage.appGroupIdentifier)
            ?? .standard
        self.defaults = resolved
        let raw = resolved.string(forKey: AnalyticsConsentStorage.key)
        self.consent = raw.flatMap(AnalyticsConsent.init(rawValue:)) ?? .unset
    }

    private var persistedConsent: AnalyticsConsent {
        let raw = defaults.string(forKey: Self.key)
        return raw.flatMap(AnalyticsConsent.init(rawValue:)) ?? .unset
    }

    /// The single check the Amplitude wrapper reads on every call. This re-reads
    /// the shared App Group value so long-lived extension processes observe host
    /// revocation immediately instead of trusting launch-time cached state.
    public var isGranted: Bool { persistedConsent == .granted }

    /// Whether the user has answered the opt-in prompt yet (drives first-run UI).
    public var hasDecided: Bool { persistedConsent != .unset }

    public func grant() { consent = .granted }
    public func decline() { consent = .declined }
    /// Revoke = decline. Stops all future sends; flushes nothing.
    public func revoke() { consent = .declined }
}

#if canImport(Combine)
extension AnalyticsConsentStore: ObservableObject {}
#endif

/// Read-only consent gate for the **widget and keyboard extensions**. They run in
/// separate processes and must never construct the full `@MainActor`
/// `AnalyticsConsentStore` or mutate consent — they only ask "did the host grant?"
/// before emitting their outcome-only events. Returns `false` (dark) whenever the
/// shared suite is missing or the value is anything other than `granted`.
public enum AnalyticsConsentReader {
    public static func isGranted(
        appGroupIdentifier: String = AnalyticsConsentStorage.appGroupIdentifier,
        key: String = AnalyticsConsentStorage.key
    ) -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroupIdentifier) else { return false }
        return defaults.string(forKey: key) == AnalyticsConsent.granted.rawValue
    }
}
