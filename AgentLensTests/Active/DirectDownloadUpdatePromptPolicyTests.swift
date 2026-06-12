import Foundation
import XCTest
@testable import OpenBurnBar

/// Prompt-state machine for the direct-download updater: "Later" defers a
/// build until the next launch or 24 hours (whichever comes first), and
/// security-critical releases re-prompt regardless of any deferral. Nothing is
/// persisted, so a "Later" can never permanently mute a build the way the
/// legacy UserDefaults-before-runModal flow did.
final class DirectDownloadUpdatePromptPolicyTests: XCTestCase {

    private func makeRelease(
        build: String = "200",
        version: String = "2.0.0",
        critical: Bool = false
    ) -> DirectDownloadRelease {
        DirectDownloadRelease(
            version: version,
            build: build,
            downloadUrl: URL(string: "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/OpenBurnBar-2.0.0.dmg")!,
            appcastUrl: URL(string: "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/appcast.xml"),
            length: 1024,
            sha256: String(repeating: "ab", count: 32),
            sparkleEdSignature: "c2lnbmF0dXJl",
            critical: critical
        )
    }

    func testFreshPolicyPrompts() {
        let policy = DirectDownloadUpdatePromptPolicy()
        XCTAssertTrue(policy.shouldPrompt(for: makeRelease(), at: Date()))
    }

    func testLaterDefersSameBuildWithinWindow() {
        var policy = DirectDownloadUpdatePromptPolicy()
        let now = Date()
        policy.noteDeferred(build: "200", at: now)

        XCTAssertFalse(policy.shouldPrompt(for: makeRelease(build: "200"), at: now))
        XCTAssertFalse(
            policy.shouldPrompt(for: makeRelease(build: "200"), at: now.addingTimeInterval(23 * 60 * 60)),
            "A deferred build must stay quiet inside the 24h window"
        )
    }

    func testDeferralExpiresAfter24Hours() {
        var policy = DirectDownloadUpdatePromptPolicy()
        let now = Date()
        policy.noteDeferred(build: "200", at: now)

        XCTAssertTrue(
            policy.shouldPrompt(for: makeRelease(build: "200"), at: now.addingTimeInterval(24 * 60 * 60)),
            "Later must defer, not mute: the prompt returns at the 24h re-check"
        )
    }

    func testDifferentBuildPromptsDespiteDeferral() {
        var policy = DirectDownloadUpdatePromptPolicy()
        let now = Date()
        policy.noteDeferred(build: "200", at: now)

        XCTAssertTrue(
            policy.shouldPrompt(for: makeRelease(build: "201"), at: now),
            "A newer build than the deferred one must prompt immediately"
        )
    }

    func testCriticalReleaseRepromptsDespiteActiveDeferral() {
        var policy = DirectDownloadUpdatePromptPolicy()
        let now = Date()
        policy.noteDeferred(build: "200", at: now)

        XCTAssertTrue(
            policy.shouldPrompt(for: makeRelease(build: "200", critical: true), at: now.addingTimeInterval(60)),
            "Security-critical releases must re-prompt even inside the deferral window"
        )
    }

    func testCustomDeferralIntervalIsHonored() {
        var policy = DirectDownloadUpdatePromptPolicy(deferralInterval: 60)
        let now = Date()
        policy.noteDeferred(build: "200", at: now)

        XCTAssertFalse(policy.shouldPrompt(for: makeRelease(build: "200"), at: now.addingTimeInterval(59)))
        XCTAssertTrue(policy.shouldPrompt(for: makeRelease(build: "200"), at: now.addingTimeInterval(60)))
    }

    func testNewDeferralReplacesOldOne() {
        var policy = DirectDownloadUpdatePromptPolicy()
        let now = Date()
        policy.noteDeferred(build: "200", at: now)
        policy.noteDeferred(build: "201", at: now)

        XCTAssertEqual(policy.deferral?.build, "201")
        XCTAssertTrue(
            policy.shouldPrompt(for: makeRelease(build: "200"), at: now),
            "Only the most recently deferred build is suppressed"
        )
    }
}
