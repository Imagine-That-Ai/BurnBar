import Foundation
@testable import OpenBurnBar

/// Shared analytics test doubles. The fake transport captures every send and
/// start/stop, so tests can prove the consent gate keeps analytics dark until
/// opt-in, carries the right name/props after opt-in, and goes silent on revoke.
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

@MainActor
func makeIsolatedAnalyticsDefaults() -> UserDefaults {
    let suiteName = "com.openburnbar.tests.analytics.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
