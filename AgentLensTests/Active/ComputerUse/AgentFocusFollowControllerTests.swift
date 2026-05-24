#if canImport(AppKit) && !DISTRIBUTION_MAS
import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class AgentFocusFollowControllerTests: XCTestCase {
    func testImmediateModeSwitchesOncePerActivation() async throws {
        var switches: [CGWindowID?] = []
        let controller = AgentFocusFollowController(
            mode: .immediate,
            targetResolver: { nil },
            targetSwitcher: { _, windowID in switches.append(windowID) },
            focusContextSink: { _ in }
        )

        controller.start(sessionId: "session-1")
        controller.recordActivationForTesting(target("Chrome", windowID: 10))
        controller.recordActivationForTesting(target("Xcode", windowID: 11))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(switches, [10, 11])
        controller.stop()
    }

    func testDebouncedModeSuppressesSub500MillisecondBounce() async throws {
        let clock = TestAgentFocusFollowClock()
        var switches: [CGWindowID?] = []
        let controller = AgentFocusFollowController(
            mode: .debounced,
            clock: clock,
            targetResolver: { nil },
            targetSwitcher: { _, windowID in switches.append(windowID) },
            focusContextSink: { _ in }
        )

        controller.start(sessionId: "session-1")
        controller.recordActivationForTesting(target("Chrome", windowID: 10))
        controller.recordActivationForTesting(target("Xcode", windowID: 11))
        await clock.waitForSleepers(3)
        await clock.wakeAll()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(switches, [11])
        controller.stop()
    }

    func testSmartModeHoldsDominantAppThroughFlurryAndSwitchesOnLull() async throws {
        let clock = TestAgentFocusFollowClock()
        var switches: [CGWindowID?] = []
        let controller = AgentFocusFollowController(
            mode: .smart,
            clock: clock,
            targetResolver: { nil },
            targetSwitcher: { _, windowID in switches.append(windowID) },
            focusContextSink: { _ in }
        )

        controller.start(sessionId: "session-1")
        controller.recordActivationForTesting(target("Chrome", windowID: 10))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(switches, [10])

        controller.recordActivationForTesting(target("Slack", windowID: 12))
        controller.recordActivationForTesting(target("Xcode", windowID: 13))
        await clock.waitForSleepers(3)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(switches, [10])

        await clock.wakeAll()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(switches, [10, 13])
        controller.stop()
    }

    func testOpenBurnBarPopoverActivationDoesNotRetargetMirrorCapture() async throws {
        let clock = TestAgentFocusFollowClock()
        var switches: [CGWindowID?] = []
        let controller = AgentFocusFollowController(
            mode: .smart,
            clock: clock,
            targetResolver: { nil },
            targetSwitcher: { _, windowID in switches.append(windowID) },
            focusContextSink: { _ in }
        )

        controller.start(sessionId: "session-1")
        controller.recordActivationForTesting(target("OpenBurnBar", bundleIdentifier: "com.openburnbar.app", windowID: 99))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(switches, [])

        controller.recordActivationForTesting(target("Chrome", windowID: 10))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(switches, [10])

        controller.recordActivationForTesting(target("Slack", windowID: 12))
        await clock.waitForSleepers(2)
        controller.recordActivationForTesting(target("OpenBurnBar", bundleIdentifier: "com.openburnbar.app", windowID: 99))
        await clock.wakeAll()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(switches, [10])
        controller.stop()
    }

    func testOffModeDoesNotRetargetUntilReenabled() async throws {
        var switches: [CGWindowID?] = []
        let controller = AgentFocusFollowController(
            mode: .off,
            targetResolver: { nil },
            targetSwitcher: { _, windowID in switches.append(windowID) },
            focusContextSink: { _ in }
        )

        controller.start(sessionId: "session-1")
        controller.recordActivationForTesting(target("Chrome", windowID: 10))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(switches, [])

        controller.setMode(.immediate)
        controller.recordActivationForTesting(target("Xcode", windowID: 11))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(switches, [11])
        controller.stop()
    }

    private func target(
        _ appName: String,
        bundleIdentifier: String? = nil,
        windowID: CGWindowID
    ) -> AgentFocusFollowTarget {
        AgentFocusFollowTarget(
            appName: appName,
            bundleIdentifier: bundleIdentifier ?? "com.test.\(appName.lowercased())",
            windowTitle: "\(appName) Window",
            windowID: windowID
        )
    }
}

private actor TestAgentFocusFollowClock: AgentFocusFollowClock {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func sleep(for seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func wakeAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func waitForSleepers(_ count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }
}
#endif
