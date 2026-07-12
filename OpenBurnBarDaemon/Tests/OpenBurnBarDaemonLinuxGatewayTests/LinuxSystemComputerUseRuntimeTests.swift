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
        capture: TestLinuxSystemCaptureAdapter,
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
