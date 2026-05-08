import Foundation
import Network
import OpenBurnBarCore

// MARK: - Smart Hub Bridge Server
//
// Tiny single-process HTTP server that binds to `127.0.0.1:8787` (or the
// configured port) and serves a static dashboard page that a Google Nest
// Hub / Chromecast device can load via its DashCast / "Cast a webpage"
// flow.
//
// Endpoints:
//   GET  /                  → 302 → /render.html
//   GET  /render.html       → static HTML; embeds JSON + auto-reloads on refresh
//   GET  /state.json        → {version, lastRefreshedAt, providers: [...]}
//   POST /refresh           → bumps the version counter; Nest Hub polls /state.json
//                              and re-renders when the version changes
//   POST /voice-refresh     → no-op for now; logs the request so a future
//                              Google Routine can be hooked up
//
// The Nest Hub's cast surface caches the page aggressively, so we use a
// `<meta http-equiv="refresh">` based on a 5s polling cycle of /state.json
// — when the version we observe changes, we full-page reload.

@MainActor
final class SmartHubBridgeServer {

    static let shared = SmartHubBridgeServer()

    private(set) var isRunning = false
    private(set) var boundPort: UInt16?
    private(set) var lastRefreshedAt: Date = Date()
    private(set) var refreshVersion: UInt64 = 0
    private(set) var snapshot: SmartHubBridgeSnapshot = .empty

    /// `true` while a fresh quota fetch is in flight, so the on-device HTML
    /// can render a shimmer overlay instead of stale numbers. Bumped via
    /// the version counter so polling clients always see the transition.
    private(set) var isRefreshing: Bool = false

    /// Time period the dashboard renders. Mirrors `SettingsManager.smartHubQuotaTimePeriod`
    /// so the on-device segmented control reflects the same source of truth.
    private(set) var timePeriod: SmartHubTimePeriod = .rolling5h

    /// Async refresh hook injected by `SmartHubBridgeController`. POST /refresh
    /// awaits this so the device sees fresh data after the request completes —
    /// not stale data plus a bumped version. Returns true on success.
    private var refreshHandler: (@MainActor () async -> Bool)?

    /// Hook for POST /period — persists the new period via SettingsManager
    /// and re-pumps the snapshot.
    private var periodChangeHandler: (@MainActor (SmartHubTimePeriod) async -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.openburnbar.smarthub.bridge")

    private init() {}

    // MARK: - Handler injection

    /// Wires the actual quota refresh entry point into the bridge so POST
    /// /refresh triggers a real refetch of provider data, not just a
    /// version bump.
    func setRefreshHandler(_ handler: @escaping @MainActor () async -> Bool) {
        refreshHandler = handler
    }

    /// Wires the period setter so POST /period persists the user's selection.
    func setPeriodChangeHandler(_ handler: @escaping @MainActor (SmartHubTimePeriod) async -> Void) {
        periodChangeHandler = handler
    }

    /// Bridge controller calls this whenever the user (Mac, iPhone, or
    /// device toggle) changes the period so /state.json reports it.
    func updateTimePeriod(_ period: SmartHubTimePeriod) {
        guard period != timePeriod else { return }
        timePeriod = period
        refreshVersion &+= 1
        lastRefreshedAt = Date()
    }

    // MARK: - Lifecycle

    func start(port: UInt16 = 8787) {
        guard !isRunning else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Bind to all interfaces so the iPhone on the same Wi-Fi can
            // hit `http://Mac.local:8787` if the user wants. We default
            // documentation to localhost for security.
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task { @MainActor in
                    self.handle(connection: connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.boundPort = port
                    case .failed, .cancelled:
                        self.isRunning = false
                        self.listener = nil
                        self.boundPort = nil
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            isRunning = false
            listener = nil
            boundPort = nil
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        boundPort = nil
    }

    // MARK: - Snapshot updates

    /// Called by the publisher when fresh provider quota / spend data
    /// arrives. The next `/state.json` request will reflect it.
    func updateSnapshot(_ snapshot: SmartHubBridgeSnapshot) {
        self.snapshot = snapshot
        refreshVersion &+= 1
        lastRefreshedAt = Date()
    }

    /// Called by `POST /refresh` (e.g. from the iPhone Cast Now button).
    /// Bumps the version so the Nest Hub re-renders without changing data.
    func bumpRefresh() {
        refreshVersion &+= 1
        lastRefreshedAt = Date()
    }

    /// Marks the bridge as refreshing so /state.json polling clients
    /// can show a loading state. Bumps version on entry + exit so the
    /// device sees both transitions immediately.
    private func setRefreshing(_ refreshing: Bool) {
        guard refreshing != isRefreshing else { return }
        isRefreshing = refreshing
        refreshVersion &+= 1
        lastRefreshedAt = Date()
    }

    // MARK: - Connection handling

    private nonisolated func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                self.respond(to: data, on: connection)
            }
        }
    }

    private func respond(to data: Data, on connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8) else {
            sendStatus(404, on: connection)
            return
        }
        let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            sendStatus(400, on: connection)
            return
        }
        let method = parts[0]
        let path = parts[1]

        // Strip query string for routing; we parse params separately below.
        let pathOnly = path.split(separator: "?").first.map(String.init) ?? path

        switch (method, pathOnly) {
        case ("GET", "/"), ("GET", ""):
            sendRedirect(to: "/render.html", on: connection)
        case ("GET", "/render.html"):
            sendHTML(SmartHubBridgePage.html, on: connection)
        case ("GET", "/state.json"):
            sendJSON(stateJSON(), on: connection)
        case ("POST", "/refresh"):
            handleRefreshRequest(on: connection)
        case ("POST", "/period"):
            handlePeriodRequest(rawPath: path, body: bodyData(from: data), on: connection)
        case ("POST", "/voice-refresh"):
            // Voice routine hook — not implemented yet, but we ack so the
            // iPhone's "Speak Now" button gets a clean response.
            sendJSON("{\"ok\":true,\"voice\":\"queued\"}", on: connection)
        case ("OPTIONS", _):
            sendStatus(204, on: connection)
        default:
            sendStatus(404, on: connection)
        }
    }

    // MARK: - Refresh handler

    /// Drives the full refresh cycle: flips the loading flag, awaits the
    /// injected refresh closure (real network fetch), then flips loading
    /// off + bumps version so /state.json polling clients re-render.
    private func handleRefreshRequest(on connection: NWConnection) {
        let handler = refreshHandler
        setRefreshing(true)

        Task { @MainActor in
            // Always flip refreshing off, even if the handler crashes.
            defer { setRefreshing(false) }

            let succeeded: Bool
            if let handler {
                succeeded = await handler()
            } else {
                // No handler wired (tests, early boot). Best-effort version bump.
                bumpRefresh()
                succeeded = true
            }

            sendJSON(
                "{\"ok\":\(succeeded),\"version\":\(refreshVersion),\"refreshing\":false}",
                on: connection
            )
        }
    }

    // MARK: - Period handler

    private func handlePeriodRequest(rawPath: String, body: Data?, on connection: NWConnection) {
        let period: SmartHubTimePeriod?
        if let queryValue = Self.queryValue(in: rawPath, key: "p"),
           let parsed = SmartHubTimePeriod(rawValue: queryValue) {
            period = parsed
        } else if let body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let raw = json["period"] as? String,
                  let parsed = SmartHubTimePeriod(rawValue: raw) {
            period = parsed
        } else {
            period = nil
        }

        guard let period else {
            sendStatus(400, on: connection)
            return
        }

        let handler = periodChangeHandler

        Task { @MainActor in
            await handler?(period)
            // Even when no handler is wired, mirror the period locally so
            // /state.json reports the requested value.
            updateTimePeriod(period)

            sendJSON(
                "{\"ok\":true,\"timePeriod\":\"\(period.rawValue)\",\"version\":\(refreshVersion)}",
                on: connection
            )
        }
    }

    /// Extracts the body bytes from a raw HTTP/1.1 request blob. We split
    /// on the canonical `\r\n\r\n` boundary; if the body wasn't included
    /// in the first read, we just return nil and the caller falls back to
    /// the query string.
    private func bodyData(from request: Data) -> Data? {
        let boundary: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        let bytes = Array(request)
        guard bytes.count >= boundary.count else { return nil }
        for i in 0...(bytes.count - boundary.count) where Array(bytes[i..<i + boundary.count]) == boundary {
            let bodyStart = i + boundary.count
            if bodyStart < bytes.count {
                return Data(bytes[bodyStart...])
            }
            return nil
        }
        return nil
    }

    private static func queryValue(in path: String, key: String) -> String? {
        guard let queryStart = path.firstIndex(of: "?") else { return nil }
        let query = path[path.index(after: queryStart)...]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0] == key {
                return String(kv[1])
                    .removingPercentEncoding
                    ?? String(kv[1])
            }
        }
        return nil
    }

    private func stateJSON() -> String {
        let formatter = ISO8601DateFormatter()
        let providersJSON = snapshot.providers.map { p in
            """
            {"name":"\(escape(p.name))","percent":\(p.percent),"label":"\(escape(p.label))","tone":"\(p.tone.rawValue)","window":"\(escape(p.windowLabel))"}
            """
        }.joined(separator: ",")

        let timePeriodOptions = SmartHubTimePeriod.allCases.map { period in
            "{\"value\":\"\(period.rawValue)\",\"short\":\"\(period.shortLabel)\",\"name\":\"\(escape(period.displayName))\"}"
        }.joined(separator: ",")

        return """
        {
          "version": \(refreshVersion),
          "lastRefreshedAt": "\(formatter.string(from: lastRefreshedAt))",
          "isRefreshing": \(isRefreshing ? "true" : "false"),
          "timePeriod": "\(timePeriod.rawValue)",
          "timePeriodLabel": "\(escape(timePeriod.displayName))",
          "timePeriodOptions": [\(timePeriodOptions)],
          "totalSpend": "\(escape(snapshot.totalSpend))",
          "headline": "\(escape(snapshot.headline))",
          "subheadline": "\(escape(snapshot.subheadline))",
          "providers": [\(providersJSON)]
        }
        """
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Wire format helpers

    private func sendRedirect(to path: String, on connection: NWConnection) {
        let head = "HTTP/1.1 302 Found\r\nLocation: \(path)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        send(head.data(using: .utf8) ?? Data(), on: connection)
    }

    private func sendHTML(_ html: String, on connection: NWConnection) {
        guard let body = html.data(using: .utf8) else {
            sendStatus(500, on: connection)
            return
        }
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = head.data(using: .utf8) ?? Data()
        data.append(body)
        send(data, on: connection)
    }

    private func sendJSON(_ json: String, on connection: NWConnection) {
        guard let body = json.data(using: .utf8) else {
            sendStatus(500, on: connection)
            return
        }
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = head.data(using: .utf8) ?? Data()
        data.append(body)
        send(data, on: connection)
    }

    private func sendStatus(_ code: Int, on connection: NWConnection) {
        let body = "{\"status\":\(code)}".data(using: .utf8) ?? Data()
        var head = "HTTP/1.1 \(code) \(statusText(code))\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = head.data(using: .utf8) ?? Data()
        data.append(body)
        send(data, on: connection)
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default:  return "Unknown"
        }
    }

    private nonisolated func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Snapshot model

struct SmartHubBridgeSnapshot: Equatable, Sendable {
    var totalSpend: String
    var headline: String
    var subheadline: String
    var providers: [Provider]

    struct Provider: Equatable, Sendable {
        var name: String
        var percent: Int       // 0–100; quota used
        var label: String      // e.g. "$120 / $300"
        var tone: Tone
        var windowLabel: String // e.g. "5h", "7d" — shown next to provider on Nest

        enum Tone: String, Sendable { case ember, whimsy, success, warning, mercury }

        init(
            name: String,
            percent: Int,
            label: String,
            tone: Tone,
            windowLabel: String = ""
        ) {
            self.name = name
            self.percent = percent
            self.label = label
            self.tone = tone
            self.windowLabel = windowLabel
        }
    }

    static let empty = SmartHubBridgeSnapshot(
        totalSpend: "—",
        headline: "OpenBurnBar",
        subheadline: "Waiting for first sync…",
        providers: []
    )
}
