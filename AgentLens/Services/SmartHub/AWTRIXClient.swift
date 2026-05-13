import Foundation
import OpenBurnBarCore

// MARK: - AWTRIX HTTP Client

struct AWTRIXClient: @unchecked Sendable {
    private static let minimumCustomAppLifetimeSeconds = 900
    private static let sentinelPublishOrder: [SentinelApp] = [.right, .select, .left]

    /// AWTRIX names the BurnBar custom app `openburnbar0` (see
    /// `pushCustomApp`). The sentinel apps are durable sibling apps used
    /// purely for input detection: when the user taps Left/Right on the
    /// device, AWTRIX navigates to one of these names, the input loop notices
    /// the change in `/api/stats.app`, fires the bound action, and immediately
    /// switches the device back to `openburnbar0`. OpenBurnBar disables
    /// AWTRIX auto-rotation while leaving physical navigation unblocked so
    /// sentinels are reached by button presses, not by idle carousel cycling.
    enum SentinelApp: String, CaseIterable {
        case left
        case select
        case right

        var appName: String {
            switch self {
            case .left: return "openburnbar_btn_left"
            case .select: return "openburnbar_btn_select"
            case .right: return "openburnbar_btn_right"
            }
        }
    }

    struct ProbeResult: Equatable, Sendable {
        let status: PixelClockProbeStatus
        let message: String
    }

    struct DiscoveryResult: Equatable, Sendable {
        let config: PixelClockConfig
        let probe: ProbeResult
    }

    enum ClientError: LocalizedError, Equatable {
        case invalidBaseURL
        case invalidResponse
        case httpStatus(Int)
        case localNetworkBlocked

        var errorDescription: String? {
            switch self {
            case .invalidBaseURL:
                return "Pixel Clock host or port is invalid."
            case .invalidResponse:
                return "Pixel Clock returned an invalid response."
            case .httpStatus(let status):
                return "Pixel Clock returned HTTP \(status)."
            case .localNetworkBlocked:
                return AWTRIXClient.localNetworkBlockedMessage
            }
        }
    }

    static let localNetworkBlockedMessage = "macOS is blocking OpenBurnBar from local devices. Open System Settings, go to Privacy & Security > Local Network, and turn on OpenBurnBar."

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Default probe used by the heartbeat. We give the device a generous
    /// 6-second budget split across two attempts because real-world TC001 wifi
    /// shows 100–250 ms latency with occasional 500 ms spikes after the clock
    /// auto-dims its CPU. A single 3 s probe was too tight and the heartbeat
    /// was bailing into the unreachable branch on healthy clocks.
    func probe(config: PixelClockConfig) async -> ProbeResult {
        let first = await probe(config: config, timeout: 3)
        if first.status == .awtrixReady || first.status == .stockUlanziFirmware {
            return first
        }
        // Quick retry — the same socket warmup that helps `curl` recover from
        // a wifi-sleep cycle helps us too. Don't retry on `.error` /
        // `.unsupported` (those mean the host answered with a bad shape, not
        // that it was slow).
        guard first.status == .unreachable else { return first }
        try? await Task.sleep(nanoseconds: 200_000_000)
        return await probe(config: config, timeout: 3)
    }

    func currentAppName(config: PixelClockConfig, timeout: TimeInterval = 2) async -> String? {
        guard let statsURL = endpoint(config: config, path: "/api/stats") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(for: request(url: statsURL, method: "GET", timeout: timeout))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return json["app"] as? String
        } catch {
            return nil
        }
    }

    func discover(
        config: PixelClockConfig,
        candidateHosts: [String]? = nil,
        candidatePorts: [Int]? = nil
    ) async -> DiscoveryResult {
        // 1) The configured host is almost always correct — retry-probe it
        //    first so a single dropped packet doesn't kick us into the slow
        //    discovery sweep.
        let firstProbe = await probe(config: config)
        if firstProbe.status == .awtrixReady || firstProbe.status == .stockUlanziFirmware {
            return DiscoveryResult(config: config, probe: firstProbe)
        }

        // 2) AWTRIX Light publishes a Bonjour record (`awtrix_<id>._http._tcp.`).
        //    When DHCP shuffles the clock to a new IP, the configured host goes
        //    stale but mDNS still points us at the right device almost
        //    instantly — no full /24 sweep required.
        if candidateHosts == nil {
            let bonjourHosts = await LocalNetworkDiscovery.bonjourDiscoverAwtrixHosts(timeout: 3)
            for host in bonjourHosts where host != config.host.trimmingCharacters(in: .whitespacesAndNewlines) {
                var candidate = config
                candidate.host = host
                candidate.port = 80
                let probeResult = await probe(config: candidate, timeout: 2.5)
                if probeResult.status == .awtrixReady || probeResult.status == .stockUlanziFirmware {
                    return DiscoveryResult(config: candidate, probe: probeResult)
                }
            }
        }

        // 3) Fall back to the active LAN netmask — covers the case where
        //    Bonjour was suppressed by the router or the clock hasn't
        //    re-announced yet. Some home mesh networks use /22 or wider
        //    segments, so a /24-only sweep would miss valid DHCP moves.
        let hosts = candidateHosts ?? LocalNetworkDiscovery.pixelClockCandidateHosts(configuredHost: config.host)
        let ports = unique(candidatePorts ?? [config.clampedPort, 80])
            .filter { (1...65_535).contains($0) }
        let configuredHost = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = hosts.flatMap { host in
            ports.map { port -> PixelClockConfig in
                var next = config
                next.host = host
                next.port = port
                return next
            }
        }
        .filter { candidate in
            candidate.host != configuredHost || candidate.clampedPort != config.clampedPort
        }

        let scanTimeout: TimeInterval = candidates.count > 32 ? 0.8 : 1.2
        return await scanCandidates(
            candidates,
            fallback: DiscoveryResult(config: config, probe: firstProbe),
            timeout: scanTimeout
        )
    }

    private func scanCandidates(
        _ candidates: [PixelClockConfig],
        fallback: DiscoveryResult,
        timeout: TimeInterval
    ) async -> DiscoveryResult {
        var bestFallback = fallback
        var iterator = candidates.makeIterator()
        let maxConcurrent = min(32, max(1, candidates.count))
        var inFlight = 0
        var shouldStop = false

        await withTaskGroup(of: DiscoveryResult.self) { group in
            func enqueue(_ candidate: PixelClockConfig) {
                inFlight += 1
                group.addTask {
                    let result = await probe(
                        config: candidate,
                        timeout: timeout,
                        stockFallbackOnTransportFailure: false
                    )
                    return DiscoveryResult(config: candidate, probe: result)
                }
            }

            while inFlight < maxConcurrent, let candidate = iterator.next() {
                enqueue(candidate)
            }

            while inFlight > 0, let result = await group.next() {
                inFlight -= 1
                if result.probe.status == .awtrixReady {
                    bestFallback = result
                    shouldStop = true
                    group.cancelAll()
                    break
                }
                if result.probe.status == .stockUlanziFirmware,
                   bestFallback.probe.status != .stockUlanziFirmware {
                    bestFallback = result
                }
                if !shouldStop, let candidate = iterator.next() {
                    enqueue(candidate)
                }
            }
        }

        return bestFallback
    }

    private func probe(
        config: PixelClockConfig,
        timeout: TimeInterval,
        stockFallbackOnTransportFailure: Bool = true
    ) async -> ProbeResult {
        guard let statsURL = endpoint(config: config, path: "/api/stats") else {
            return ProbeResult(status: .error, message: ClientError.invalidBaseURL.localizedDescription)
        }

        do {
            let (data, response) = try await session.data(for: request(url: statsURL, method: "GET", timeout: timeout))
            guard let http = response as? HTTPURLResponse else {
                return ProbeResult(status: .error, message: ClientError.invalidResponse.localizedDescription)
            }
            if (200..<300).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) {
                if Self.looksLikeAwtrixStats(json) {
                    return ProbeResult(status: .awtrixReady, message: "AWTRIX HTTP API is ready at \(config.host).")
                }
                if await looksLikeStockUlanzi(config: config, timeout: timeout) {
                    let message = await stockUlanziMessage(config: config, timeout: timeout)
                    return ProbeResult(status: .stockUlanziFirmware, message: message)
                }
                return ProbeResult(status: .unsupported, message: "Stats endpoint answered, but it did not look like AWTRIX.")
            }
            if await looksLikeStockUlanzi(config: config, timeout: timeout) {
                let message = await stockUlanziMessage(config: config, timeout: timeout)
                return ProbeResult(status: .stockUlanziFirmware, message: message)
            }
            return ProbeResult(status: .unsupported, message: "AWTRIX stats endpoint returned HTTP \(http.statusCode).")
        } catch {
            if stockFallbackOnTransportFailure,
               await looksLikeStockUlanzi(config: config, timeout: timeout) {
                let message = await stockUlanziMessage(config: config, timeout: timeout)
                return ProbeResult(status: .stockUlanziFirmware, message: message)
            }
            if Self.isLocalNetworkBlocked(error) {
                return ProbeResult(status: .unreachable, message: Self.localNetworkBlockedMessage)
            }
            return ProbeResult(status: .unreachable, message: error.localizedDescription)
        }
    }

    func pushCustomApp(pages: [[String: Any]], config: PixelClockConfig) async throws {
        guard let activePage = pages.first else { return }
        let body = try JSONSerialization.data(withJSONObject: activePage, options: [])
        try await pushCustomApp(body: body, config: config)
    }

    func pushCustomApp(body: Data, config: PixelClockConfig) async throws {
        guard let url = endpoint(config: config, path: "/api/custom", query: "name=\(PixelClockQuotaRenderer.appName)0") else {
            throw ClientError.invalidBaseURL
        }
        try await sendJSON(url: url, method: "POST", body: body)
    }

    func testNotify(page: PixelClockRenderedPage, config: PixelClockConfig, sound: String? = nil) async throws {
        guard let url = endpoint(config: config, path: "/api/notify") else {
            throw ClientError.invalidBaseURL
        }
        var payload: [String: Any] = [
            "text": page.text,
            "color": page.color,
            "duration": page.durationSeconds,
            "scrollSpeed": page.scrollSpeed
        ]
        if let progress = page.progress {
            payload["progress"] = progress
            payload["progressC"] = page.color
        }
        if let sound, !sound.isEmpty {
            payload["sound"] = sound
        }
        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        try await sendJSON(url: url, method: "POST", body: body)
    }

    func removeCustomApp(config: PixelClockConfig) async throws {
        let body = "{}".data(using: .utf8) ?? Data()
        let baseNames = [PixelClockQuotaRenderer.appName] + (0..<16).map { "\(PixelClockQuotaRenderer.appName)\($0)" }
        let names = baseNames + SentinelApp.allCases.map(\.appName)
        for name in names {
            guard let url = endpoint(config: config, path: "/api/custom", query: "name=\(name)") else {
                throw ClientError.invalidBaseURL
            }
            try await sendJSON(url: url, method: "POST", body: body)
        }
    }

    /// Registers small placeholder custom apps so the device's Left/Right
    /// arrow keys have a unique app name to land on. These pages are dim
    /// arrow glyphs with a short display duration but a long custom-app
    /// lifetime: the app must still exist when the user presses a hardware
    /// button minutes later, otherwise AWTRIX just reloads/cycles the
    /// `openburnbar0` page and the input controller never sees the sentinel.
    func pushSentinelApps(config: PixelClockConfig) async throws {
        // AWTRIX app navigation commonly follows creation order. Publishing
        // right/select/left after `openburnbar0` makes the physical Right key
        // land on the right sentinel and the physical Left key wrap to the
        // left sentinel.
        for sentinel in Self.sentinelPublishOrder {
            let body = try JSONSerialization.data(
                withJSONObject: sentinelPayload(for: sentinel, config: config),
                options: []
            )
            guard let url = endpoint(config: config, path: "/api/custom", query: "name=\(sentinel.appName)") else {
                throw ClientError.invalidBaseURL
            }
            try await sendJSON(url: url, method: "POST", body: body)
        }
    }

    /// Switches the device to the named custom app via `/api/switch` (AWTRIX
    /// 3 ≥ v0.96). Some firmware forks return 404 on `/api/switch`; in that
    /// case we fall back to `/api/nextapp` until the requested app is the
    /// active one. The fallback path is bounded by `maxSteps` so a missing
    /// app cannot loop forever.
    func switchToApp(name: String, config: PixelClockConfig) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["name": name], options: [])
        if let url = endpoint(config: config, path: "/api/switch") {
            do {
                try await sendJSON(url: url, method: "POST", body: body)
                return
            } catch ClientError.httpStatus(404) {
                // Fall through to the carousel-step fallback.
            }
        }
        guard let nextURL = endpoint(config: config, path: "/api/nextapp") else {
            throw ClientError.invalidBaseURL
        }
        let stepBody = "{}".data(using: .utf8) ?? Data()
        let maxSteps = 24
        for _ in 0..<maxSteps {
            if await currentAppName(config: config) == name { return }
            try await sendJSON(url: nextURL, method: "POST", body: stepBody)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    private func sentinelPayload(for sentinel: SentinelApp, config: PixelClockConfig) -> [String: Any] {
        let color = "#404040"
        let arrow: [PixelClockDrawInstruction]
        switch sentinel {
        case .left:
            arrow = [
                .fillRect(x: 14, y: 3, width: 4, height: 1, color: color),
                .fillRect(x: 13, y: 4, width: 1, height: 1, color: color),
                .fillRect(x: 14, y: 5, width: 1, height: 1, color: color)
            ]
        case .right:
            arrow = [
                .fillRect(x: 14, y: 3, width: 4, height: 1, color: color),
                .fillRect(x: 18, y: 4, width: 1, height: 1, color: color),
                .fillRect(x: 17, y: 5, width: 1, height: 1, color: color)
            ]
        case .select:
            arrow = [
                .fillRect(x: 15, y: 3, width: 2, height: 2, color: color)
            ]
        }
        return [
            "text": "",
            "color": color,
            "duration": 1,
            "lifetime": sentinelLifetimeSeconds(config: config),
            "save": false,
            "noScroll": true,
            "draw": arrow.map(\.awtrixObject)
        ]
    }

    private func sentinelLifetimeSeconds(config: PixelClockConfig) -> Int {
        max(Self.minimumCustomAppLifetimeSeconds, config.clampedUpdateInterval * 4, 60)
    }

    func applyBrightnessIfNeeded(config: PixelClockConfig) async throws {
        guard let brightness = config.clampedBrightness else { return }
        guard let url = endpoint(config: config, path: "/api/settings") else {
            throw ClientError.invalidBaseURL
        }
        let body = try JSONSerialization.data(withJSONObject: ["BRI": brightness], options: [])
        try await sendJSON(url: url, method: "POST", body: body)
    }

    func configureStockSimulator(
        config: PixelClockConfig,
        serverHost: String,
        serverPort: Int = 7001
    ) async throws {
        guard let url = endpoint(config: config, path: "/app_switch") else {
            throw ClientError.invalidBaseURL
        }
        // Stock Ulanzi does not clear an already-enabled checkbox when
        // the field is omitted from this partial POST. Send
        // `isShowIp=off` explicitly so the firmware stops cycling the
        // device's LAN IP between our custom quota pages — the only
        // thing on the clock should be providers the user is tracking.
        let body = formBody([
            ("page", "app_switch"),
            ("isAwtrixSimulator", "on"),
            ("awtrixServer", serverHost),
            ("awtrixPort", "\(min(max(serverPort, 1), 65_535))"),
            ("isShowIp", "off")
        ])
        try await sendForm(url: url, method: "POST", body: body)
    }

    /// AWTRIX Light's built-in TIME/DATE/HUM/TEMP/BAT apps cycle
    /// alongside whatever custom apps you push. Disable them and stop
    /// automatic app rotation via `/api/settings` so only OpenBurnBar drives
    /// the visible frame cadence. Keep physical navigation unblocked because
    /// the Left/Select/Right bindings depend on the device navigating to the
    /// sentinel apps.
    func disableAwtrixNativeApps(config: PixelClockConfig) async throws {
        guard let url = endpoint(config: config, path: "/api/settings") else {
            throw ClientError.invalidBaseURL
        }
        let body = try JSONSerialization.data(
            withJSONObject: [
                "ATRANS": false,
                "BLOCKN": false,
                "TIM": false,
                "DAT": false,
                "HUM": false,
                "TEMP": false,
                "BAT": false
            ],
            options: []
        )
        try await sendJSON(url: url, method: "POST", body: body)
    }

    private func sendJSON(url: URL, method: String, body: Data) async throws {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(url: url, method: method, body: body))
        } catch {
            if Self.isLocalNetworkBlocked(error) {
                throw ClientError.localNetworkBlocked
            }
            throw error
        }
        _ = data
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ClientError.httpStatus(http.statusCode)
        }
    }

    private func sendForm(url: URL, method: String, body: Data) async throws {
        var request = request(url: url, method: method, body: body)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Self.isLocalNetworkBlocked(error) {
                throw ClientError.localNetworkBlocked
            }
            throw error
        }
        _ = data
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard (200..<400).contains(http.statusCode) else {
            throw ClientError.httpStatus(http.statusCode)
        }
    }

    private func formBody(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs: [String] = fields.map { key, value in
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }
        let encodedForm: String = pairs.joined(separator: "&")
        return Data(encodedForm.utf8)
    }

    static func isLocalNetworkBlocked(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain,
              nsError.code == NSURLErrorNotConnectedToInternet else {
            return false
        }
        let values = nsError.userInfo.values.map { "\($0)" }
        if values.contains(where: { $0.localizedCaseInsensitiveContains("local network prohibited") }) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            let underlyingValues = underlying.userInfo.values.map { "\($0)" }
            return underlyingValues.contains(where: { $0.localizedCaseInsensitiveContains("local network prohibited") })
        }
        return false
    }

    private func looksLikeStockUlanzi(config: PixelClockConfig, timeout: TimeInterval = 3) async -> Bool {
        guard let url = endpoint(config: config, path: "/") else { return false }
        do {
            let (data, response) = try await session.data(for: request(url: url, method: "GET", timeout: timeout))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return false
            }
            return html.localizedCaseInsensitiveContains("Ulanzi Clock")
                || html.localizedCaseInsensitiveContains("Ulanzi Pixel Clock")
        } catch {
            return false
        }
    }

    private struct StockSimulatorSettings: Equatable {
        var enabled: Bool
        var server: String?
        var port: Int?
    }

    private func stockUlanziMessage(config: PixelClockConfig, timeout: TimeInterval) async -> String {
        let macIP = LocalNetworkDiscovery.preferredLANIPv4Address()
        let macHint = macIP.map { "this Mac (\($0))" } ?? "this Mac's LAN IP"
        let setup = await stockSimulatorSettings(config: config, timeout: timeout)

        if setup?.enabled == true,
           setup?.server?.trimmingCharacters(in: .whitespacesAndNewlines) == config.host.trimmingCharacters(in: .whitespacesAndNewlines) {
            return "Stock Ulanzi firmware detected at \(config.host). Awtrix Simulator is pointing at the clock itself; set Server IP to \(macHint) and Server Port to \(setup?.port ?? 7001)."
        }

        if setup?.enabled == true, let server = setup?.server, let port = setup?.port {
            return "Stock Ulanzi firmware detected at \(config.host). Awtrix Simulator is enabled for \(server):\(port); direct /api/custom control still requires AWTRIX Light firmware or an AWTRIX host server."
        }

        return "Stock Ulanzi firmware detected at \(config.host). Enable Awtrix Simulator and set Server IP to \(macHint), or flash AWTRIX Light for direct HTTP control."
    }

    private func stockSimulatorSettings(config: PixelClockConfig, timeout: TimeInterval) async -> StockSimulatorSettings? {
        guard let url = endpoint(config: config, path: "/app_switch") else { return nil }
        do {
            let (data, response) = try await session.data(for: request(url: url, method: "GET", timeout: timeout))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }
            return StockSimulatorSettings(
                enabled: html.range(
                    of: #"name=['"]isAwtrixSimulator['"][^>]*checked"#,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil,
                server: firstInputValue(named: "awtrixServer", in: html),
                port: firstInputValue(named: "awtrixPort", in: html).flatMap(Int.init)
            )
        } catch {
            return nil
        }
    }

    private func firstInputValue(named name: String, in html: String) -> String? {
        let pattern = #"name=['"]\#(NSRegularExpression.escapedPattern(for: name))['"][^>]*value=['"]([^'"]*)['"]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[valueRange])
    }

    private func request(url: URL, method: String, body: Data? = nil, timeout: TimeInterval = 3) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func endpoint(config: PixelClockConfig, path: String, query: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = config.clampedPort == 80 ? nil : config.clampedPort
        components.path = path
        components.percentEncodedQuery = query
        return components.url
    }

    private func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func looksLikeAwtrixStats(_ json: Any) -> Bool {
        guard let object = json as? [String: Any] else { return false }
        let keys = Set(object.keys.map { $0.lowercased() })
        let awtrixKeys: Set<String> = [
            "app",
            "bat",
            "battery",
            "bri",
            "free_heap",
            "heap",
            "hum",
            "humidity",
            "ip_address",
            "ldr",
            "lux",
            "matrix",
            "ram",
            "temp",
            "temperature",
            "uid",
            "uptime",
            "version",
            "wifi_signal"
        ]
        let matches = keys.intersection(awtrixKeys)
        if matches.count >= 3 { return true }
        return keys.contains("version") && matches.subtracting(["version"]).count >= 1
    }
}
