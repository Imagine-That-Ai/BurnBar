import Foundation

// MARK: - Cast Channel Client
//
// High-level Cast V2 driver. Owns the TLS connection + the protocol
// state machine (CONNECT → GET_STATUS → LAUNCH → set URL → heartbeat).
//
// Public API mirrors what a wizard / settings panel needs:
//   - `cast(url:)` → ensures the receiver has the DashCast app running with
//                    the requested URL loaded
//   - `stop()`    → tears down the receiver app
//   - `ping()`    → sends a heartbeat to keep the session alive
//
// Auto-recovery for stuck sessions lives in `CastReconnectStrategy`.

@MainActor
final class CastChannelClient {

    /// Public app id for DashCast — a community Cast receiver app that
    /// renders any URL. Verified against pychromecast's
    /// `DashCastController` (`APP_DASHCAST`). Replace with our own
    /// first-party receiver in Phase 2 once Google approves the app
    /// registration.
    static let dashCastAppId = "84912283"

    static let nsConnection = "urn:x-cast:com.google.cast.tp.connection"
    static let nsHeartbeat  = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let nsReceiver   = "urn:x-cast:com.google.cast.receiver"
    static let nsDashCast   = "urn:x-cast:com.madmod.dashcast"

    enum Outcome: Equatable {
        case success(sessionId: String)
        case failure(String)
        case timeout
    }

    /// Snapshot of the receiver's current app state, exposed so callers
    /// (e.g. the bridge watchdog) can decide whether to soft-refresh or
    /// hard-kick the device. `appId` is empty when the receiver is on
    /// the Backdrop / idle screen.
    struct ReceiverState: Equatable {
        let appId: String
        let sessionId: String
        let transportId: String?
        let isDashCast: Bool
    }

    private let device: CastDevice
    private let connection: CastTLSConnection

    private var heartbeatTask: Task<Void, Never>?
    private var requestCounter: Int = 1
    private var currentSessionId: String?
    private var currentTransportId: String?
    private var currentAppId: String?

    /// Pending continuations for request/response correlation. Cast V2
    /// uses a `requestId` round-trip pattern.
    private var pending: [Int: (Outcome) -> Void] = [:]

    init(device: CastDevice) {
        self.device = device
        self.connection = CastTLSConnection(host: device.host, port: device.port)
        self.connection.onMessage = { [weak self] msg in
            self?.handle(message: msg)
        }
    }

    deinit {
        heartbeatTask?.cancel()
    }

    // MARK: - Public

    /// Top-level entry — opens the channel, launches DashCast if needed,
    /// pushes the URL, and starts a heartbeat loop. Resolves with
    /// `.success` once the receiver acknowledges, `.failure(reason)` if
    /// the session can't be set up.
    func cast(url: URL) async -> Outcome {
        await ensureConnected()
        guard connection.state == .ready else {
            return .failure(connectionFailureMessage())
        }

        sendVirtual(namespace: Self.nsConnection, payload: [
            "type": "CONNECT",
            "userAgent": "OpenBurnBar/1.0"
        ], destination: CastMessage.defaultDestination)

        let launchOutcome = await launchAppIfNeeded()
        switch launchOutcome {
        case .failure(let reason): return .failure(reason)
        case .timeout:             return .timeout
        case .success:             break
        }

        // Open the virtual app channel.
        guard let transportId = currentTransportId else {
            return .failure("Missing transport id after LAUNCH")
        }
        sendVirtual(namespace: Self.nsConnection, payload: [
            "type": "CONNECT",
            "userAgent": "OpenBurnBar/1.0"
        ], destination: transportId)

        // Brief settle: DashCast occasionally drops the very first
        // LOAD if it lands on the wire before the transport CONNECT
        // has been processed, leaving the Hub stuck on the splash.
        try? await Task.sleep(nanoseconds: 250_000_000)

        sendVirtual(
            namespace: Self.nsDashCast,
            payload: Self.dashCastLoadPayload(
                url: url,
                sessionId: currentSessionId,
                reloadSeconds: 60
            ),
            destination: transportId
        )

        startHeartbeat()
        return .success(sessionId: currentSessionId ?? "")
    }

    func stop() async {
        await ensureConnected()
        guard connection.state == .ready else { return }
        if let sessionId = currentSessionId {
            await request(namespace: Self.nsReceiver, payload: [
                "type": "STOP",
                "sessionId": sessionId
            ], destination: CastMessage.defaultDestination)
        }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        connection.cancel()
    }

    /// Send a single PING. Useful for `CastReconnectStrategy` to detect
    /// zombie sessions before deciding to STOP→LAUNCH.
    func ping() async -> Bool {
        await ensureConnected()
        guard connection.state == .ready else { return false }
        sendVirtual(namespace: Self.nsHeartbeat, payload: ["type": "PING"], destination: CastMessage.defaultDestination)
        return true
    }

    /// Probe the receiver and report what app (if any) is currently
    /// running. Lets the bridge watchdog distinguish "Hub is showing
    /// our dashboard" from "Hub is on Backdrop / showing a stuck
    /// DashCast splash / showing another Cast app" — only the first
    /// is a healthy state.
    func queryReceiverState() async -> ReceiverState? {
        await ensureConnected()
        guard connection.state == .ready else { return nil }
        sendVirtual(namespace: Self.nsConnection, payload: [
            "type": "CONNECT",
            "userAgent": "OpenBurnBar/1.0"
        ], destination: CastMessage.defaultDestination)

        switch await request(
            namespace: Self.nsReceiver,
            payload: ["type": "GET_STATUS"],
            destination: CastMessage.defaultDestination,
            timeout: 4
        ) {
        case .success:
            return ReceiverState(
                appId: currentAppId ?? "",
                sessionId: currentSessionId ?? "",
                transportId: currentTransportId,
                isDashCast: currentAppId == Self.dashCastAppId
            )
        case .failure, .timeout:
            // Empty applications array → idle / Backdrop. We still
            // return a state so the caller can launch fresh.
            return ReceiverState(
                appId: "",
                sessionId: "",
                transportId: nil,
                isDashCast: false
            )
        }
    }

    /// Tear down whatever's running on the receiver and launch DashCast
    /// from scratch with the given URL. Used by the watchdog when a
    /// soft re-LOAD didn't unstick the Hub — typical symptom is the
    /// device frozen on DashCast's splash because a previous LOAD got
    /// dropped during a Wi-Fi roam.
    func forceRecast(url: URL) async -> Outcome {
        await ensureConnected()
        guard connection.state == .ready else {
            return .failure(connectionFailureMessage())
        }
        sendVirtual(namespace: Self.nsConnection, payload: [
            "type": "CONNECT",
            "userAgent": "OpenBurnBar/1.0"
        ], destination: CastMessage.defaultDestination)

        // STOP any currently-running app, regardless of which one it is.
        if let sessionId = currentSessionId, !sessionId.isEmpty {
            _ = await request(
                namespace: Self.nsReceiver,
                payload: ["type": "STOP", "sessionId": sessionId],
                destination: CastMessage.defaultDestination,
                timeout: 4
            )
        }
        currentSessionId = nil
        currentTransportId = nil
        currentAppId = nil

        // Brief settle so the receiver finishes tearing down before
        // we ask it to launch again. Without this the LAUNCH often
        // races the STOP and lands on a stale session.
        try? await Task.sleep(nanoseconds: 800_000_000)

        // Fresh LAUNCH of DashCast.
        let launch = await request(
            namespace: Self.nsReceiver,
            payload: ["type": "LAUNCH", "appId": Self.dashCastAppId],
            destination: CastMessage.defaultDestination,
            timeout: 8
        )
        switch launch {
        case .failure(let reason): return .failure(reason)
        case .timeout:             return .timeout
        case .success:             break
        }

        guard let transportId = currentTransportId else {
            return .failure("Missing transport id after forced LAUNCH")
        }
        sendVirtual(namespace: Self.nsConnection, payload: [
            "type": "CONNECT",
            "userAgent": "OpenBurnBar/1.0"
        ], destination: transportId)

        // force:true so DashCast reloads even if the URL matches what
        // it was last asked to show.
        sendVirtual(
            namespace: Self.nsDashCast,
            payload: Self.dashCastLoadPayload(
                url: url,
                sessionId: currentSessionId,
                reloadSeconds: 60,
                force: true
            ),
            destination: transportId
        )
        startHeartbeat()
        return .success(sessionId: currentSessionId ?? "")
    }

    // MARK: - Internal

    private func ensureConnected() async {
        if connection.state == .ready { return }
        connection.connect()
        // Spin until ready or failure, capped at 6s.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            switch connection.state {
            case .ready, .failed, .cancelled: return
            default:
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    private func connectionFailureMessage() -> String {
        switch connection.state {
        case .failed(let reason):
            return "Couldn't open the Cast channel to \(device.friendlyName) at \(device.host):\(device.port): \(reason)"
        case .connecting, .idle:
            return "\(device.friendlyName) is visible on Wi‑Fi, but its Cast port \(device.host):\(device.port) is not accepting connections. Reboot the display or router, then retry."
        case .cancelled:
            return "Cast channel to \(device.friendlyName) was cancelled before it connected."
        case .ready:
            return "Cast channel unexpectedly disconnected."
        }
    }

    private func launchAppIfNeeded() async -> Outcome {
        // GET_STATUS first; if DashCast already running, reuse session.
        let status = await request(
            namespace: Self.nsReceiver,
            payload: ["type": "GET_STATUS"],
            destination: CastMessage.defaultDestination,
            timeout: 4
        )
        if case .success(let sessionId) = status, !sessionId.isEmpty {
            return .success(sessionId: sessionId)
        }

        // Otherwise LAUNCH.
        return await request(
            namespace: Self.nsReceiver,
            payload: [
                "type": "LAUNCH",
                "appId": Self.dashCastAppId
            ],
            destination: CastMessage.defaultDestination,
            timeout: 8
        )
    }

    @discardableResult
    private func request(
        namespace: String,
        payload: [String: Any],
        destination: String,
        timeout: TimeInterval = 6
    ) async -> Outcome {
        let id = nextRequestId()
        var enriched = payload
        enriched["requestId"] = id

        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            pending[id] = { outcome in continuation.resume(returning: outcome) }
            sendVirtual(namespace: namespace, payload: enriched, destination: destination)

            // Timeout watchdog.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                if let cb = self.pending.removeValue(forKey: id) {
                    cb(.timeout)
                }
            }
        }
    }

    private func sendVirtual(namespace: String, payload: [String: Any], destination: String) {
        guard let json = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let utf8 = String(data: json, encoding: .utf8) else { return }
        let msg = CastMessage(
            sourceId: CastMessage.defaultSource,
            destinationId: destination,
            namespace: namespace,
            payloadUTF8: utf8
        )
        connection.send(msg)
    }

    static func dashCastLoadPayload(
        url: URL,
        sessionId: String?,
        reloadSeconds: TimeInterval,
        force: Bool = false
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "url": url.absoluteString,
            "force": force,
            "reload": reloadSeconds > 0,
            "reload_time": reloadSeconds > 0 ? reloadSeconds * 1_000 : 0
        ]
        if let sessionId, !sessionId.isEmpty {
            payload["sessionId"] = sessionId
        }
        return payload
    }

    private func nextRequestId() -> Int {
        defer { requestCounter += 1 }
        return requestCounter
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                _ = await self?.ping()
            }
        }
    }

    // MARK: - Inbound message handler

    private func handle(message: CastMessage) {
        guard let data = message.payloadUTF8.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // requestId-based correlation.
        if let requestId = obj["requestId"] as? Int, let cb = pending.removeValue(forKey: requestId) {
            switch obj["type"] as? String {
            case "RECEIVER_STATUS":
                if let status = obj["status"] as? [String: Any],
                   let apps = status["applications"] as? [[String: Any]],
                   let first = apps.first,
                   let sessionId = first["sessionId"] as? String {
                    currentSessionId = sessionId
                    currentTransportId = first["transportId"] as? String
                    currentAppId = first["appId"] as? String
                    cb(.success(sessionId: sessionId))
                } else {
                    // Empty applications array means the receiver is on
                    // Backdrop / idle — clear our cached app state so
                    // the next launch path actually fires.
                    currentSessionId = nil
                    currentTransportId = nil
                    currentAppId = nil
                    cb(.failure("Receiver returned no sessions"))
                }
            case "LAUNCH_ERROR":
                let reason = (obj["reason"] as? String) ?? "LAUNCH_ERROR"
                // `NOT_FOUND` from a Cast receiver means the device
                // doesn't have the requested receiver app installed
                // (or refuses to install it). On audio-only devices
                // — Nest Mini, Nest Audio, Google Home — DashCast
                // simply can't be launched at all. Surface the
                // human-readable cause so the recovery UI can show a
                // useful message.
                if reason == "NOT_FOUND" {
                    cb(.failure("This device can't display web pages. Pick a Nest Hub or Chromecast."))
                } else {
                    cb(.failure(reason))
                }
            default:
                cb(.success(sessionId: ""))
            }
            return
        }

        // PING from device — auto-reply with PONG to keep session alive.
        if message.namespace == Self.nsHeartbeat,
           obj["type"] as? String == "PING" {
            sendVirtual(namespace: Self.nsHeartbeat, payload: ["type": "PONG"], destination: CastMessage.defaultDestination)
        }
    }
}
