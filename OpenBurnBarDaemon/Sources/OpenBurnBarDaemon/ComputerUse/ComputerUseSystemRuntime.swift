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
        let captureReady = portalReady
            && media.capabilitiesKnown
            && media.pipeWireSource
            && media.vp9Encode
        let inputReady = inputAdapterReady && !killSwitchActive
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
        active = ActiveSession(
            sessionID: sessionID,
            onRevoked: onRevoked,
            captureLive: false,
            monitorTask: nil
        )
        do {
            try await captureAdapter.startOutboundCapture(
                targetBitrateBps: 1_500_000,
                codec: .vp9,
                onFrame: { frame in frameQueue.offer(frame) },
                onStopped: { [weak self] reason in
                    frameQueue.finish()
                    Task { await self?.captureStopped(sessionID: sessionID, reason: reason) }
                }
            )
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
            }
            throw error
        }
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
              inputAdapter.isAvailableForSystemInput() else {
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
