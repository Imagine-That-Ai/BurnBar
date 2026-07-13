import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore

protocol ComputerUseSystemRuntime: Sendable {
    typealias RevocationHandler = @Sendable (_ sessionID: ComputerUseSessionID, _ reason: String) async -> Void

    func capability() async -> ComputerUseSystemCapabilitySnapshot
    func start(
        sessionID: ComputerUseSessionID,
        onRevoked: @escaping RevocationHandler
    ) async throws
    func stop(sessionID: ComputerUseSessionID) async
    func stopAll() async
    func dispatch(sessionID: ComputerUseSessionID, action: MacInputAction) async throws -> BurnBarJSONValue
    func inspect(sessionID: ComputerUseSessionID, action: MacInspectAction) async throws -> BurnBarJSONValue
    /// The most recent independently-decodable capture frame for the live
    /// session, used as before-action evidence on phone approvals. `nil`
    /// when the session is not live or no keyframe has arrived yet —
    /// approvals then publish without visual evidence (previous behavior).
    func latestCaptureEvidence(sessionID: ComputerUseSessionID) async -> ComputerUseSystemCaptureEvidence?
}

/// Before-action visual evidence captured from the System (whole-desktop)
/// capture pipeline. The payload is the newest encoded keyframe — an
/// intra-coded frame that decodes to a full image on its own — plus the
/// exact MIME type of the encoding so approval surfaces never have to
/// guess what they were handed.
public struct ComputerUseSystemCaptureEvidence: Sendable, Equatable {
    public let data: Data
    public let mimeType: String
    public let presentationTimestampMillis: UInt64

    public init(data: Data, mimeType: String, presentationTimestampMillis: UInt64) {
        self.data = data
        self.mimeType = mimeType
        self.presentationTimestampMillis = presentationTimestampMillis
    }
}

extension ComputerUseSystemRuntime {
    /// Fail-closed default: runtimes that do not surface capture evidence
    /// publish approvals without a screenshot rather than fabricating one.
    func latestCaptureEvidence(sessionID: ComputerUseSessionID) async -> ComputerUseSystemCaptureEvidence? {
        nil
    }
}

#if os(Linux)
import OpenBurnBarMedia

actor LinuxSystemComputerUseRuntime: ComputerUseSystemRuntime {
    enum RuntimeError: Error, LocalizedError, Equatable {
        case unavailable(String)
        case sessionAlreadyActive
        case sessionNotActive
        case captureDidNotBecomeLive
        case captureStopped(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let reason):
                return "Linux System Computer Use is unavailable: \(reason)"
            case .sessionAlreadyActive:
                return "A Linux System Computer Use capture is already active."
            case .sessionNotActive:
                return "Linux System Computer Use input is not active."
            case .captureDidNotBecomeLive:
                return "Linux System Computer Use capture did not produce a live PipeWire frame."
            case .captureStopped(let reason):
                return "Linux System Computer Use capture stopped: \(reason)"
            }
        }
    }

    typealias MediaProbe = @Sendable () -> MercuryLinuxMediaCapabilities
    typealias PortalProbe = @Sendable () -> Bool
    typealias KillSwitchProbe = @Sendable () -> Bool

    private struct ActiveSession {
        let sessionID: ComputerUseSessionID
        let onRevoked: RevocationHandler
        var captureLive: Bool
        var monitorTask: Task<Void, Never>?
        /// Newest independently-decodable (keyframe) capture frame, written
        /// synchronously from the capture callback so approval evidence never
        /// waits on the actor.
        let latestKeyframe: Locked<MediaFrame?>
    }

    private let captureAdapter: any MercuryLinuxCaptureAdapterProtocol
    private let inputAdapter: LinuxComputerUseInputAdapter
    private let mediaProbe: MediaProbe
    private let portalProbe: PortalProbe
    private let killSwitchProbe: KillSwitchProbe
    private let firstFrameTimeout: Duration
    private let monitorInterval: Duration
    private var active: ActiveSession?

    init(
        captureAdapter: any MercuryLinuxCaptureAdapterProtocol = MercuryLinuxCaptureAdapter(),
        inputAdapter: LinuxComputerUseInputAdapter = LinuxComputerUseInputAdapter(),
        mediaProbe: @escaping MediaProbe = MercuryLinuxCaptureEngine.mediaCapabilities,
        portalProbe: @escaping PortalProbe = {
            ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        },
        killSwitchProbe: @escaping KillSwitchProbe = {
            LinuxPrivilegedInputKillFlag.isActive()
                || LinuxPrivilegedInputKillFlag.environmentKillSwitchActive()
        },
        firstFrameTimeout: Duration = .seconds(8),
        monitorInterval: Duration = .seconds(1)
    ) {
        self.captureAdapter = captureAdapter
        self.inputAdapter = inputAdapter
        self.mediaProbe = mediaProbe
        self.portalProbe = portalProbe
        self.killSwitchProbe = killSwitchProbe
        self.firstFrameTimeout = firstFrameTimeout
        self.monitorInterval = monitorInterval
    }

    func capability() -> ComputerUseSystemCapabilitySnapshot {
        let media = mediaProbe()
        let portalReady = portalProbe()
        let killSwitchActive = killSwitchProbe()
        let inputAdapterReady = inputAdapter.isAvailableForSystemInput()
        let inputCoverageReady = inputAdapter.hasFullSystemInputCoverage()
        let captureReady = portalReady
            && media.capabilitiesKnown
            && media.pipeWireSource
            && media.vp9Encode
        let inputReady = inputAdapterReady && inputCoverageReady && !killSwitchActive
        let available = captureReady && inputReady
        let activeNow = available && active?.captureLive == true
        let reason: String
        if killSwitchActive {
            reason = "computer_use_kill_switch_active"
        } else if !portalReady {
            reason = "desktop_portal_session_bus_unavailable"
        } else if !media.capabilitiesKnown || !media.pipeWireSource || !media.vp9Encode {
            reason = "pipewire_vp9_capture_unavailable"
        } else if !inputAdapterReady {
            reason = "linux_input_adapter_unavailable"
        } else if !inputCoverageReady {
            reason = "linux_input_adapter_action_coverage_incomplete"
        } else if activeNow {
            reason = "capture_and_input_live"
        } else {
            reason = "capture_and_input_ready"
        }
        return ComputerUseSystemCapabilitySnapshot(
            available: available,
            captureReady: captureReady,
            inputReady: inputReady,
            active: activeNow,
            reason: reason
        )
    }

    func start(
        sessionID: ComputerUseSessionID,
        onRevoked: @escaping RevocationHandler
    ) async throws {
        guard active == nil else { throw RuntimeError.sessionAlreadyActive }
        let readiness = capability()
        guard readiness.available else { throw RuntimeError.unavailable(readiness.reason) }

        let frameQueue = MercuryLinuxCaptureFrameQueue(bufferingNewest: 1)
        let latestKeyframe = Locked<MediaFrame?>(nil)
        active = ActiveSession(
            sessionID: sessionID,
            onRevoked: onRevoked,
            captureLive: false,
            monitorTask: nil,
            latestKeyframe: latestKeyframe
        )
        // `startOutboundCapture` suspends across portal consent, so a
        // stop/revoke can clear `active` (and no-op its capture teardown)
        // before the adapter has a live pipeline. Track that the pipeline
        // actually came up so the catch path below can stop it even after
        // `active` was already cleared by that racing stop.
        var captureStarted = false
        do {
            try await captureAdapter.startOutboundCapture(
                targetBitrateBps: 1_500_000,
                codec: .vp9,
                onFrame: { frame in
                    if frame.kind == .videoNAL, frame.flags.contains(.keyframe) {
                        latestKeyframe.withLock { $0 = frame }
                    }
                    frameQueue.offer(frame)
                },
                onStopped: { [weak self] reason in
                    frameQueue.finish()
                    Task { await self?.captureStopped(sessionID: sessionID, reason: reason) }
                }
            )
            captureStarted = true
            try await waitForFirstFrame(frameQueue.stream)
            guard var current = active, current.sessionID == sessionID else {
                throw CancellationError()
            }
            current.captureLive = true
            current.monitorTask = Task { [weak self] in
                await self?.monitor(sessionID: sessionID)
            }
            active = current
        } catch {
            if active?.sessionID == sessionID {
                active?.monitorTask?.cancel()
                active = nil
                captureAdapter.stopOutboundCapture()
            } else if captureStarted, active == nil {
                // A stop/revoke won the race while capture start was
                // suspended: its `stopOutboundCapture()` ran before the
                // pipeline existed, so the pipeline that just came up
                // belongs to no session. Tear it down instead of leaving
                // PipeWire capture running outside any session. (When a
                // NEWER session is already active it owns the adapter —
                // leave it alone.)
                captureAdapter.stopOutboundCapture()
            }
            throw error
        }
    }

    func latestCaptureEvidence(sessionID: ComputerUseSessionID) async -> ComputerUseSystemCaptureEvidence? {
        guard let active,
              active.sessionID == sessionID,
              active.captureLive,
              let frame = active.latestKeyframe.withLock({ $0 }),
              frame.payload.isEmpty == false else {
            return nil
        }
        return ComputerUseSystemCaptureEvidence(
            data: frame.payload,
            mimeType: "video/vp9",
            presentationTimestampMillis: frame.presentationTimestampMillis
        )
    }

    func stop(sessionID: ComputerUseSessionID) async {
        guard active?.sessionID == sessionID else { return }
        active?.monitorTask?.cancel()
        active = nil
        captureAdapter.stopOutboundCapture()
    }

    func stopAll() async {
        guard let sessionID = active?.sessionID else { return }
        await stop(sessionID: sessionID)
    }

    func dispatch(
        sessionID: ComputerUseSessionID,
        action: MacInputAction
    ) async throws -> BurnBarJSONValue {
        try requireLiveSession(sessionID)
        do {
            let result = try await inputAdapter.dispatch(action)
            try Task.checkCancellation()
            try requireLiveSession(sessionID)
            return result
        } catch {
            if shouldRevoke(after: error) {
                await revoke(sessionID: sessionID, reason: "linux_input_revoked")
            }
            throw error
        }
    }

    func inspect(
        sessionID: ComputerUseSessionID,
        action: MacInspectAction
    ) async throws -> BurnBarJSONValue {
        try requireLiveSession(sessionID)
        let result = try await inputAdapter.inspectAccessibility(action)
        try Task.checkCancellation()
        try requireLiveSession(sessionID)
        return result
    }

    private func requireLiveSession(_ sessionID: ComputerUseSessionID) throws {
        guard let active,
              active.sessionID == sessionID,
              active.captureLive,
              !killSwitchProbe(),
              inputAdapter.isAvailableForSystemInput(),
              inputAdapter.hasFullSystemInputCoverage() else {
            throw RuntimeError.sessionNotActive
        }
    }

    private func waitForFirstFrame(_ stream: AsyncStream<MediaFrame>) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard await iterator.next() != nil else {
                    throw RuntimeError.captureStopped("capture_pipeline_ended")
                }
            }
            group.addTask { [firstFrameTimeout] in
                try await Task.sleep(for: firstFrameTimeout)
                throw RuntimeError.captureDidNotBecomeLive
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func monitor(sessionID: ComputerUseSessionID) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: monitorInterval)
            } catch {
                return
            }
            guard active?.sessionID == sessionID else { return }
            let readiness = capability()
            if !readiness.available {
                await revoke(sessionID: sessionID, reason: readiness.reason)
                return
            }
        }
    }

    private func captureStopped(sessionID: ComputerUseSessionID, reason: String) async {
        guard active?.sessionID == sessionID else { return }
        await revoke(sessionID: sessionID, reason: "capture_stopped:\(String(reason.prefix(160)))")
    }

    private func revoke(sessionID: ComputerUseSessionID, reason: String) async {
        guard let current = active, current.sessionID == sessionID else { return }
        current.monitorTask?.cancel()
        active = nil
        captureAdapter.stopOutboundCapture()
        await current.onRevoked(sessionID, reason)
    }

    private func shouldRevoke(after error: Error) -> Bool {
        guard let adapterError = error as? LinuxComputerUseInputAdapter.AdapterError else {
            return error is CancellationError
        }
        switch adapterError {
        case .adapterUnavailable, .killSwitchActive, .commandFailed:
            return true
        case .missingCoordinate, .unsupportedAction:
            return false
        }
    }
}
#endif
