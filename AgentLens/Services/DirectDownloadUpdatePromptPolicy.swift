import Foundation

// MARK: - Prompt state machine

/// Decides whether an available release should prompt the user.
///
/// Deferral state is **in-memory only** — by design nothing is persisted, so a
/// "Later" can never permanently mute a build (the old checker persisted the
/// prompted build to UserDefaults *before* the user even responded, which
/// silenced security releases forever after a single "Later"). A "Later" now
/// defers until the next app launch or until `deferralInterval` (24h) elapses
/// within the same process, whichever comes first. Security-critical releases
/// (`critical: true` in the feed) re-prompt regardless of deferral.
struct DirectDownloadUpdatePromptPolicy: Sendable {
    struct Deferral: Equatable, Sendable {
        var build: String
        var deferredAt: Date
    }

    let deferralInterval: TimeInterval
    private(set) var deferral: Deferral?

    init(deferralInterval: TimeInterval = 24 * 60 * 60) {
        self.deferralInterval = deferralInterval
    }

    func shouldPrompt(for release: DirectDownloadRelease, at now: Date = Date()) -> Bool {
        if release.critical { return true }
        guard let deferral, deferral.build == release.build else { return true }
        return now.timeIntervalSince(deferral.deferredAt) >= deferralInterval
    }

    mutating func noteDeferred(build: String, at now: Date = Date()) {
        deferral = Deferral(build: build, deferredAt: now)
    }
}
