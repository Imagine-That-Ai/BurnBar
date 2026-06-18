import Foundation
import XCTest
@testable import OpenBurnBarAnalytics

/// Shared analytics test doubles, mirroring the macOS `AnalyticsTestSupport`.
/// The fake transport captures every send and start/stop so tests can prove the
/// consent gate keeps analytics dark until opt-in, carries the right name/props
/// after opt-in, and goes silent on revoke.
@MainActor
final class FakeAnalyticsTransport: AnalyticsTransporting {
    private(set) var isStarted = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var sent: [(name: String, category: String, properties: [String: AnalyticsValue])] = []
    private(set) var userId: String?

    func start() { isStarted = true; startCount += 1 }
    func stop() { isStarted = false; stopCount += 1 }
    func send(name: String, category: String, properties: [String: AnalyticsValue]) {
        sent.append((name, category, properties))
    }
    func setUserId(_ id: String?) { userId = id }
}

/// A transport that models the **no-API-key** production case: `start()` is a
/// no-op (the real `AmplitudeTransport` never constructs the client without a
/// key), so even a fully-consented recorder sends nothing. Proves "no key → dark
/// by construction" at the seam the recorder actually drives.
@MainActor
final class KeylessAnalyticsTransport: AnalyticsTransporting {
    private(set) var sent: [(name: String, category: String, properties: [String: AnalyticsValue])] = []
    // Never becomes started because there is no key to construct a client with.
    var isStarted: Bool { false }
    func start() { /* no key → never constructs a client, stays dark */ }
    func stop() {}
    func send(name: String, category: String, properties: [String: AnalyticsValue]) {
        // The real transport guards on `amplitude != nil`; with no client there is
        // nothing to send to. Model that: a keyless transport drops sends.
    }
    func setUserId(_ id: String?) {}
}

@MainActor
func makeIsolatedAnalyticsDefaults() -> UserDefaults {
    let suiteName = "com.openburnbar.tests.analytics.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
