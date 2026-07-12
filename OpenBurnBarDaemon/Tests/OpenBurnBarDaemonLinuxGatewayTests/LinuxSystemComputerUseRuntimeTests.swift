#if os(Linux)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OpenBurnBarMedia
@testable import OpenBurnBarDaemon
import XCTest

final class LinuxSystemComputerUseRuntimeTests: XCTestCase {
    func testRequiresCaptureAndInputBeforeAdvertisingAvailability() async {
        let capture = TestLinuxSystemCaptureAdapter(emitsFrame: true)
        let runtime = makeRuntime(capture: capture, portalReady: false)

        let capability = await runtime.capability()

        XCTAssertFalse(capability.available)
        XCTAssertFalse(capability.captureReady)
        XCTAssertTrue(capability.inputReady)
        XCTAssertEqual(capability.reason, "desktop_portal_session_bus_unavailable")
    }

    func testStartWaitsForLiveFrameThenAllowsInputAndStopRevokesBoth() async throws {
        let capture = TestLinuxSystemCaptureAdapter(emitsFrame: true)
        let runtime = makeRuntime(capture: capture)
        let sessionID = ComputerUseSessionID("system-session")

        try await runtime.start(sessionID: sessionID) { _, _ in }
        let activeCapability = await runtime.capability()
        XCTAssertTrue(activeCapability.available)
        XCTAssertTrue(activeCapability.active)

        let evidence = await runtime.latestCaptureEvidence(sessionID: sessionID)
        XCTAssertEqual(evidence?.data, Data([1, 2, 3]))
        XCTAssertEqual(evidence?.mimeType, "video/vp9")
        let wrongSessionEvidence = await runtime.latestCaptureEvidence(
            sessionID: ComputerUseSessionID("someone-else")
        )
        XCTAssertNil(wrongSessionEvidence)

        let result = try await runtime.dispatch(
            sessionID: sessionID,
            action: MacInputAction(kind: .click, displayX: 10, displayY: 20)
        )
        guard case .object(let object) = result else {
            return XCTFail("expected structured Linux input result")
        }
        XCTAssertEqual(object["adapter"], .string("x11-xtest"))

        await runtime.stop(sessionID: sessionID)
        XCTAssertEqual(capture.stopCount, 1)
        await XCTAssertThrowsErrorAsync {
            _ = try await runtime.dispatch(
                sessionID: sessionID,
                action: MacInputAction(kind: .click, displayX: 10, displayY: 20)
            )
        }
        let stoppedEvidence = await runtime.latestCaptureEvidence(sessionID: sessionID)
        XCTAssertNil(stoppedEvidence)
    }

    func testStopDuringSuspendedCaptureStartStillTearsDownThePipeline() async throws {
        let capture = GatedLinuxSystemCaptureAdapter()
        let runtime = makeRuntime(capture: capture)
        let sessionID = ComputerUseSessionID("raced-session")

        let startTask = Task {
            try await runtime.start(sessionID: sessionID) { _, _ in }
        }
        // Wait until start(...) is suspended inside the adapter's portal
        // consent, then let a stop win the race. Its stopOutboundCapture()
        // runs before any pipeline exists.
        await capture.waitUntilStartRequested()
        await runtime.stop(sessionID: sessionID)
        let stopsBeforePipeline = capture.stopCount

        // Portal consent completes: the pipeline comes up owned by no
        // session. start(...) must fail AND tear the orphan pipeline down.
        capture.releaseStart()
        await XCTAssertThrowsErrorAsync {
            try await startTask.value
        }

        XCTAssertGreaterThan(capture.stopCount, stopsBeforePipeline)
        let capability = await runtime.capability()
        XCTAssertFalse(capability.active)
    }

    func testCaptureStopRevokesSessionAndInputAuthority() async throws {
        let capture = TestLinuxSystemCaptureAdapter(emitsFrame: true)
        let runtime = makeRuntime(capture: capture)
        let sessionID = ComputerUseSessionID("revoked-session")
        let revocations = TestLinuxSystemRevocationRecorder()
        try await runtime.start(sessionID: sessionID) { sessionID, reason in
            await revocations.record(sessionID: sessionID, reason: reason)
        }

        capture.triggerStop(reason: "portal_permission_revoked")
        for _ in 0..<40 {
            if await revocations.snapshot() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let revocation = await revocations.snapshot()
        XCTAssertEqual(revocation?.0, sessionID)
        XCTAssertEqual(revocation?.1, "capture_stopped:portal_permission_revoked")
        let capability = await runtime.capability()
        XCTAssertFalse(capability.active)
    }

    func testStartFailsClosedWhenCaptureNeverProducesAFrame() async {
        let capture = TestLinuxSystemCaptureAdapter(emitsFrame: false)
        let runtime = makeRuntime(capture: capture, firstFrameTimeout: .milliseconds(20))

        await XCTAssertThrowsErrorAsync {
            try await runtime.start(sessionID: ComputerUseSessionID("no-frame")) { _, _ in }
        }
        XCTAssertEqual(capture.stopCount, 1)
        let capability = await runtime.capability()
        XCTAssertFalse(capability.active)
    }

    private func makeRuntime(
        capture: any MercuryLinuxCaptureAdapterProtocol,
        portalReady: Bool = true,
        firstFrameTimeout: Duration = .seconds(1)
    ) -> LinuxSystemComputerUseRuntime {
        let input = LinuxComputerUseInputAdapter(
            environment: { name in
                switch name {
                case "DISPLAY": ":1"
                case "DBUS_SESSION_BUS_ADDRESS": "unix:path=/tmp/test-bus"
                default: nil
                }
            },
            resolveExecutable: { $0 == "xdotool" ? "/usr/bin/xdotool" : nil },
            runCommand: { _, _ in LinuxComputerUseInputAdapter.CommandResult(exitCode: 0) }
        )
        return LinuxSystemComputerUseRuntime(
            captureAdapter: capture,
            inputAdapter: input,
            mediaProbe: {
                MercuryLinuxMediaCapabilities(
                    capabilitiesKnown: true,
                    vp9Encode: true,
                    vp9Decode: true,
                    av1Encode: false,
                    av1Decode: false,
                    opusEncode: true,
                    opusDecode: true,
                    pipeWireSource: true
                )
            },
            portalProbe: { portalReady },
            killSwitchProbe: { false },
            firstFrameTimeout: firstFrameTimeout,
            monitorInterval: .seconds(60)
        )
    }
}

private final class TestLinuxSystemCaptureAdapter: MercuryLinuxCaptureAdapterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let emitsFrame: Bool
    private var stoppedCallback: (@Sendable (String) -> Void)?
    private var stops = 0

    init(emitsFrame: Bool) {
        self.emitsFrame = emitsFrame
    }

    var stopCount: Int {
        lock.withLock { stops }
    }

    func startOutboundCapture(
        targetBitrateBps: UInt32,
        codec: MercuryLinuxCaptureCodec,
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void
    ) async throws {
        _ = targetBitrateBps
        _ = codec
        lock.withLock { stoppedCallback = onStopped }
        if emitsFrame {
            onFrame(MediaFrame(kind: .videoNAL, flags: .keyframe, payload: Data([1, 2, 3])))
        }
    }

    func stopOutboundCapture() {
        lock.withLock {
            stops += 1
            stoppedCallback = nil
        }
    }

    func setOutboundCaptureBitrate(_ targetBitrateBps: UInt32) throws {
        _ = targetBitrateBps
    }

    func triggerStop(reason: String) {
        let callback = lock.withLock { stoppedCallback }
        callback?(reason)
    }
}

/// Capture adapter whose `startOutboundCapture` suspends (like the real
/// portal-consent round trip) until the test releases it, so stop/revoke
/// races against a still-starting capture can be exercised deterministically.
private final class GatedLinuxSystemCaptureAdapter: MercuryLinuxCaptureAdapterProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stops = 0
    private var startRequested = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    var stopCount: Int {
        lock.withLock { stops }
    }

    func startOutboundCapture(
        targetBitrateBps: UInt32,
        codec: MercuryLinuxCaptureCodec,
        onFrame: @escaping @Sendable (MediaFrame) -> Void,
        onStopped: @escaping @Sendable (String) -> Void
    ) async throws {
        _ = targetBitrateBps
        _ = codec
        _ = onStopped
        lock.withLock { startRequested = true }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock { releaseContinuation = continuation }
        }
        // Pipeline is now "live" — emit a frame so the first-frame wait
        // resolves and the race lands on the post-start session guard.
        onFrame(MediaFrame(kind: .videoNAL, flags: .keyframe, payload: Data([7, 7, 7])))
    }

    func stopOutboundCapture() {
        lock.withLock { stops += 1 }
    }

    func setOutboundCaptureBitrate(_ targetBitrateBps: UInt32) throws {
        _ = targetBitrateBps
    }

    func waitUntilStartRequested() async {
        while lock.withLock({ startRequested }) == false {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseStart() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            let stored = releaseContinuation
            releaseContinuation = nil
            return stored
        }
        continuation?.resume()
    }
}

private actor TestLinuxSystemRevocationRecorder {
    private var value: (ComputerUseSessionID, String)?

    func record(sessionID: ComputerUseSessionID, reason: String) {
        value = (sessionID, reason)
    }

    func snapshot() -> (ComputerUseSessionID, String)? { value }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected async expression to throw", file: file, line: line)
    } catch {}
}
#endif
