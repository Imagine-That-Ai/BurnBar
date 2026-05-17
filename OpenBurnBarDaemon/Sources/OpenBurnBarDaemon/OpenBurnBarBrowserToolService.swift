import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import Foundation

public typealias BurnBarBrowserFetcher = @Sendable (_ url: URL) async throws -> (Data, HTTPURLResponse)
public typealias BurnBarBrowserOpener = @Sendable (_ url: URL) throws -> Void
public typealias BurnBarExecutableLocator = @Sendable (_ executableName: String) -> String?
public typealias BurnBarPlaywrightBrowserActionExecutor = @Sendable (
    _ action: BurnBarBrowserActionKind,
    _ arguments: BurnBarBrowserActionArguments
) async throws -> OpenBurnBarPlaywrightDriver.Response

private struct BurnBarStoredBrowserToolingFile: Codable, Hashable {
    var updatedAt: Date
    var preferredEngine: BurnBarBrowserEngineKind
    var allowExternalNavigation: Bool
    var engineEnabledState: [String: Bool]
}

public actor BurnBarBrowserToolService {
    private let fileURL: URL
    private let fetcher: BurnBarBrowserFetcher
    private let opener: BurnBarBrowserOpener
    private let locateExecutable: BurnBarExecutableLocator
    private let playwrightExecutor: BurnBarPlaywrightBrowserActionExecutor?
    private let logger: BurnBarDaemonLogger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cachedState: BurnBarStoredBrowserToolingFile?
    private var playwrightDriver: OpenBurnBarPlaywrightDriver?

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultBrowserToolingURL,
        fetcher: BurnBarBrowserFetcher? = nil,
        opener: BurnBarBrowserOpener? = nil,
        locateExecutable: BurnBarExecutableLocator? = nil,
        playwrightExecutor: BurnBarPlaywrightBrowserActionExecutor? = nil,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "browser-tooling")
    ) {
        self.fileURL = fileURL
        self.fetcher = fetcher ?? { url in
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, httpResponse)
        }
        self.opener = opener ?? { url in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url.absoluteString]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "BurnBarBrowserToolService",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Failed to open URL in the system browser."]
                )
            }
        }
        self.locateExecutable = locateExecutable ?? { name in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let candidates = [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                "\(home)/.local/bin/\(name)",
                "\(home)/.nvm/versions/node/v20.20.2/bin/\(name)",
                "/usr/bin/\(name)"
            ]
            if let direct = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return direct
            }
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            process.arguments = [name]
            process.standardOutput = output
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            } catch {
                return nil
            }
        }
        self.playwrightExecutor = playwrightExecutor
        self.logger = logger
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func snapshot() throws -> BurnBarBrowserToolingSnapshot {
        let state = try loadStateIfNeeded()
        let engines = BurnBarBrowserEngineKind.allCases.map { kind in
            let executablePath = executablePath(for: kind)
            return BurnBarBrowserEngineSnapshot(
                kind: kind,
                displayName: Self.displayName(for: kind),
                isEnabled: state.engineEnabledState[kind.rawValue] ?? Self.defaultEnabledState(for: kind),
                status: status(for: kind, executablePath: executablePath),
                executablePath: executablePath,
                detail: detail(for: kind, executablePath: executablePath),
                supportsFetch: kind == .urlSession,
                supportsExternalNavigation: kind == .systemBrowser
            )
        }

        return BurnBarBrowserToolingSnapshot(
            updatedAt: state.updatedAt,
            preferredEngine: state.preferredEngine,
            allowExternalNavigation: state.allowExternalNavigation,
            engines: engines
        )
    }

    public func update(_ request: BurnBarBrowserToolingUpdateRequest) throws -> BurnBarBrowserToolingSnapshot {
        var state = try loadStateIfNeeded()
        state.preferredEngine = request.preferredEngine
        state.allowExternalNavigation = request.allowExternalNavigation
        state.engineEnabledState = Dictionary(uniqueKeysWithValues: request.enginePreferences.map { ($0.kind.rawValue, $0.isEnabled) })
        state.updatedAt = Date()
        try persist(state)
        return try snapshot()
    }

    public func performAction(_ request: BurnBarBrowserActionRequest) async throws -> BurnBarBrowserActionResponse {
        let snapshot = try snapshot()
        let engine = request.preferredEngine ?? snapshot.preferredEngine
        guard let selectedEngine = snapshot.engines.first(where: { $0.kind == engine }) else {
            return BurnBarBrowserActionResponse(
                action: request.action,
                engine: engine,
                ok: false,
                summary: "Unknown browser engine.",
                detail: nil,
                recordedAt: Date()
            )
        }

        guard selectedEngine.isEnabled else {
            return BurnBarBrowserActionResponse(
                action: request.action,
                engine: engine,
                ok: false,
                summary: "\(selectedEngine.displayName) is disabled.",
                detail: "Enable the engine in OpenBurnBar Settings before using it.",
                recordedAt: Date()
            )
        }

        switch request.action {
        case .openExternal:
            guard snapshot.allowExternalNavigation else {
                return BurnBarBrowserActionResponse(
                    action: request.action,
                    engine: engine,
                    ok: false,
                    summary: "External navigation is disabled.",
                    detail: "Enable external navigation in OpenBurnBar Settings.",
                    recordedAt: Date()
                )
            }
            guard engine == .systemBrowser else {
                return BurnBarBrowserActionResponse(
                    action: request.action,
                    engine: engine,
                    ok: false,
                    summary: "Open External only supports the system browser today.",
                    detail: "Choose System Browser to launch URLs.",
                    recordedAt: Date()
                )
            }

            let url = try validatedURL(request.url)
            try opener(url)
            return BurnBarBrowserActionResponse(
                action: request.action,
                engine: engine,
                ok: true,
                summary: "Opened \(url.host ?? url.absoluteString) in the system browser.",
                recordedAt: Date()
            )
        case .fetchDocument, .extractLinks:
            guard engine == .urlSession else {
                return BurnBarBrowserActionResponse(
                    action: request.action,
                    engine: engine,
                    ok: false,
                    summary: "\(selectedEngine.displayName) is visible for setup/status only.",
                    detail: "Document fetch and link extraction currently run through the daemon fetcher.",
                    recordedAt: Date()
                )
            }

            let url = try validatedURL(request.url)
            let (data, response) = try await fetcher(url)
            guard (200 ..< 300).contains(response.statusCode) else {
                return BurnBarBrowserActionResponse(
                    action: request.action,
                    engine: engine,
                    ok: false,
                    summary: "Fetch failed.",
                    detail: "HTTP \(response.statusCode)",
                    recordedAt: Date()
                )
            }

            let html = String(decoding: data, as: UTF8.self)
            let title = Self.extractTitle(from: html)
            let stripped = Self.stripHTML(html)
            let links = Self.extractLinks(from: html, limit: request.maxLinks)
            switch request.action {
            case .fetchDocument:
                return BurnBarBrowserActionResponse(
                    action: request.action,
                    engine: engine,
                    ok: true,
                    summary: "Fetched \(title ?? url.host ?? url.absoluteString).",
                    detail: nil,
                    title: title,
                    document: stripped,
                    recordedAt: Date()
                )
            case .extractLinks:
                return BurnBarBrowserActionResponse(
                    action: request.action,
                    engine: engine,
                    ok: true,
                    summary: "Extracted \(links.count) link\(links.count == 1 ? "" : "s").",
                    title: title,
                    document: stripped.map { String($0.prefix(280)) },
                    links: links,
                    recordedAt: Date()
                )
            case .openExternal,
                 .click, .fill, .goto, .key, .select, .screenshot, .extract:
                fatalError("Handled above.")
            }
        case .click, .fill, .goto, .key, .select, .screenshot, .extract:
            guard engine == .playwright else {
                return BurnBarBrowserActionResponse(
                    action: request.action,
                    engine: engine,
                    ok: false,
                    summary: "\(selectedEngine.displayName) cannot run interactive browser actions.",
                    detail: "Choose Playwright for \(request.action.rawValue).",
                    recordedAt: Date()
                )
            }
            let arguments = request.arguments ?? BurnBarBrowserActionArguments(url: request.url)
            let response = try await executePlaywrightAction(request.action, arguments: arguments)
            return browserResponse(
                from: response,
                action: request.action,
                engine: engine
            )
        }
    }

    private func executePlaywrightAction(
        _ action: BurnBarBrowserActionKind,
        arguments: BurnBarBrowserActionArguments
    ) async throws -> OpenBurnBarPlaywrightDriver.Response {
        if let playwrightExecutor {
            return try await playwrightExecutor(action, arguments)
        }

        let driver = try await playwrightDriverForDefaultSession()
        switch action {
        case .click:
            return try await driver.click(
                selector: arguments.selector,
                positionX: arguments.positionX,
                positionY: arguments.positionY,
                timeoutMillis: arguments.timeoutMillis
            )
        case .fill:
            guard let selector = arguments.selector, let text = arguments.text else {
                return OpenBurnBarPlaywrightDriver.Response(
                    id: -1,
                    ok: false,
                    result: nil,
                    error: "fill requires selector and text",
                    elapsedMillis: nil
                )
            }
            return try await driver.fill(selector: selector, text: text, timeoutMillis: arguments.timeoutMillis)
        case .goto:
            guard let url = arguments.url else {
                return OpenBurnBarPlaywrightDriver.Response(
                    id: -1,
                    ok: false,
                    result: nil,
                    error: "goto requires url",
                    elapsedMillis: nil
                )
            }
            return try await driver.goto(url: url, timeoutMillis: arguments.timeoutMillis)
        case .key:
            guard let key = arguments.key else {
                return OpenBurnBarPlaywrightDriver.Response(
                    id: -1,
                    ok: false,
                    result: nil,
                    error: "key requires key",
                    elapsedMillis: nil
                )
            }
            return try await driver.key(key)
        case .select:
            guard let selector = arguments.selector, let value = arguments.value else {
                return OpenBurnBarPlaywrightDriver.Response(
                    id: -1,
                    ok: false,
                    result: nil,
                    error: "select requires selector and value",
                    elapsedMillis: nil
                )
            }
            return try await driver.select(selector: selector, value: value)
        case .screenshot:
            return try await driver.screenshot()
        case .extract:
            return try await driver.extract(selector: arguments.selector)
        case .openExternal, .fetchDocument, .extractLinks:
            return OpenBurnBarPlaywrightDriver.Response(
                id: -1,
                ok: false,
                result: nil,
                error: "unsupported Playwright action \(action.rawValue)",
                elapsedMillis: nil
            )
        }
    }

    private func playwrightDriverForDefaultSession() async throws -> OpenBurnBarPlaywrightDriver {
        if let playwrightDriver {
            return playwrightDriver
        }
        guard let nodePath = locateExecutable("node") else {
            throw OpenBurnBarPlaywrightDriver.DriverError.binaryNotFound
        }
        let bridgeScriptURL = Self.defaultBridgeScriptURL()
        guard FileManager.default.fileExists(atPath: bridgeScriptURL.path) else {
            throw OpenBurnBarPlaywrightDriver.DriverError.bridgeScriptMissing
        }
        let sessionId = ComputerUseSessionID("daemon-browser-tool-service")
        let userDataDirectory = BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent("browser-tool-service", isDirectory: true)
            .appendingPathComponent("playwright-profile", isDirectory: true)
        let driver = OpenBurnBarPlaywrightDriver(
            configuration: OpenBurnBarPlaywrightDriver.Configuration(
                nodeExecutablePath: nodePath,
                bridgeScriptPath: bridgeScriptURL,
                userDataDirectory: userDataDirectory,
                headless: false
            ),
            sessionId: sessionId,
            logger: logger
        )
        try await driver.start()
        playwrightDriver = driver
        return driver
    }

    private func browserResponse(
        from response: OpenBurnBarPlaywrightDriver.Response,
        action: BurnBarBrowserActionKind,
        engine: BurnBarBrowserEngineKind
    ) -> BurnBarBrowserActionResponse {
        let resultObject: [String: BurnBarJSONValue]
        if case let .object(object)? = response.result {
            resultObject = object
        } else {
            resultObject = [:]
        }
        let elapsed = response.elapsedMillis.map { "\($0) ms" }
        guard response.ok else {
            return BurnBarBrowserActionResponse(
                action: action,
                engine: engine,
                ok: false,
                summary: "Playwright \(action.rawValue) failed.",
                detail: [response.error, elapsed].compactMap { $0 }.joined(separator: " · "),
                recordedAt: Date()
            )
        }

        switch action {
        case .goto:
            let finalURL = resultObject.stringValue(forKey: "finalURL")
                ?? resultObject.stringValue(forKey: "url")
                ?? "page"
            let status = resultObject.intValue(forKey: "status")
            return BurnBarBrowserActionResponse(
                action: action,
                engine: engine,
                ok: true,
                summary: status.map { "Opened \(finalURL) (HTTP \($0))." } ?? "Opened \(finalURL).",
                detail: elapsed,
                recordedAt: Date()
            )
        case .extract:
            let text = resultObject.stringValue(forKey: "text")
            return BurnBarBrowserActionResponse(
                action: action,
                engine: engine,
                ok: true,
                summary: "Extracted page content.",
                detail: elapsed,
                document: text,
                recordedAt: Date()
            )
        case .screenshot:
            let bytes = resultObject.intValue(forKey: "sizeBytes")
            let base64 = resultObject.stringValue(forKey: "base64")
            return BurnBarBrowserActionResponse(
                action: action,
                engine: engine,
                ok: true,
                summary: bytes.map { "Captured screenshot (\($0) bytes)." } ?? "Captured screenshot.",
                detail: elapsed,
                document: base64,
                recordedAt: Date()
            )
        case .click:
            let selector = resultObject.stringValue(forKey: "selector")
            return BurnBarBrowserActionResponse(
                action: action,
                engine: engine,
                ok: true,
                summary: selector.map { "Clicked \($0)." } ?? "Clicked page coordinates.",
                detail: elapsed,
                recordedAt: Date()
            )
        case .fill:
            let selector = resultObject.stringValue(forKey: "selector")
            let charCount = resultObject.intValue(forKey: "charCount")
            let target = selector ?? "field"
            return BurnBarBrowserActionResponse(
                action: action,
                engine: engine,
                ok: true,
                summary: charCount.map { "Filled \(target) with \($0) character\($0 == 1 ? "" : "s")." } ?? "Filled \(target).",
                detail: elapsed,
                recordedAt: Date()
            )
        case .key:
            let combo = resultObject.stringValue(forKey: "combo") ?? "key"
            return BurnBarBrowserActionResponse(
                action: action,
                engine: engine,
                ok: true,
                summary: "Pressed \(combo).",
                detail: elapsed,
                recordedAt: Date()
            )
        case .select:
            let selector = resultObject.stringValue(forKey: "selector") ?? "select"
            let value = resultObject.stringValue(forKey: "value") ?? "value"
            return BurnBarBrowserActionResponse(
                action: action,
                engine: engine,
                ok: true,
                summary: "Selected \(value) in \(selector).",
                detail: elapsed,
                recordedAt: Date()
            )
        case .openExternal, .fetchDocument, .extractLinks:
            return BurnBarBrowserActionResponse(
                action: action,
                engine: engine,
                ok: true,
                summary: "Browser action completed.",
                detail: elapsed,
                recordedAt: Date()
            )
        }
    }

    private func loadStateIfNeeded() throws -> BurnBarStoredBrowserToolingFile {
        if let cachedState {
            return cachedState
        }

        let defaultState = Self.defaultState()
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedState = defaultState
            return defaultState
        }

        let data = try Data(contentsOf: fileURL)
        let decoded = try decoder.decode(BurnBarStoredBrowserToolingFile.self, from: data)
        cachedState = decoded
        return decoded
    }

    private func persist(_ state: BurnBarStoredBrowserToolingFile) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        cachedState = state
    }

    private func executablePath(for kind: BurnBarBrowserEngineKind) -> String? {
        switch kind {
        case .systemBrowser:
            return FileManager.default.isExecutableFile(atPath: "/usr/bin/open") ? "/usr/bin/open" : nil
        case .urlSession:
            return nil
        case .playwright:
            return locateExecutable("playwright")
        case .lightpanda:
            return locateExecutable("lightpanda")
        }
    }

    private static func defaultBridgeScriptURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["OPENBURNBAR_PLAYWRIGHT_BRIDGE"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: override, isDirectory: false)
        }
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let candidates = [
            Bundle.main.resourceURL?
                .appendingPathComponent("PlaywrightBridge", isDirectory: true)
                .appendingPathComponent("openburnbar-playwright-bridge.js", isDirectory: false),
            cwd.appendingPathComponent("OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js"),
            cwd.appendingPathComponent("Resources/PlaywrightBridge/openburnbar-playwright-bridge.js")
        ].compactMap { $0 }
        return candidates.first(where: { fm.fileExists(atPath: $0.path) }) ?? candidates[0]
    }

    private func status(for kind: BurnBarBrowserEngineKind, executablePath: String?) -> BurnBarBrowserToolStatus {
        switch kind {
        case .urlSession:
            return .ready
        case .systemBrowser:
            return executablePath == nil ? .unavailable : .ready
        case .playwright, .lightpanda:
            return executablePath == nil ? .unavailable : .ready
        }
    }

    private func detail(for kind: BurnBarBrowserEngineKind, executablePath: String?) -> String {
        switch kind {
        case .urlSession:
            return "Daemon-side fetch plane for page text and links."
        case .systemBrowser:
            return executablePath == nil ? "System browser launcher is unavailable." : "Uses /usr/bin/open to launch URLs."
        case .playwright:
            return executablePath == nil ? "Install Playwright CLI to enable Computer Use browser automation." : "Ready for Computer Use browser automation."
        case .lightpanda:
            return executablePath == nil ? "Install Lightpanda to expose lightweight browser automation." : "Detected for future browser automation."
        }
    }

    private func validatedURL(_ rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), trimmed.isEmpty == false else {
            throw NSError(
                domain: "BurnBarBrowserToolService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Browser action URL is invalid."]
            )
        }
        return url
    }

    private static func defaultState() -> BurnBarStoredBrowserToolingFile {
        BurnBarStoredBrowserToolingFile(
            updatedAt: Date(),
            preferredEngine: .urlSession,
            allowExternalNavigation: true,
            engineEnabledState: Dictionary(uniqueKeysWithValues: BurnBarBrowserEngineKind.allCases.map { ($0.rawValue, defaultEnabledState(for: $0)) })
        )
    }

    private static func defaultEnabledState(for kind: BurnBarBrowserEngineKind) -> Bool {
        switch kind {
        case .systemBrowser, .urlSession:
            return true
        case .playwright:
            return true
        case .lightpanda:
            return false
        }
    }

    private static func displayName(for kind: BurnBarBrowserEngineKind) -> String {
        switch kind {
        case .systemBrowser: return "System Browser"
        case .urlSession: return "Daemon Fetcher"
        case .playwright: return "Playwright"
        case .lightpanda: return "Lightpanda"
        }
    }

    private static func extractTitle(from html: String) -> String? {
        guard let range = html.range(
            of: "(?is)<title[^>]*>(.*?)</title>",
            options: .regularExpression
        ) else {
            return nil
        }
        let fragment = String(html[range])
        return fragment
            .replacingOccurrences(of: "(?is)</?title[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripHTML(_ html: String) -> String? {
        let stripped = html
            .replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : String(stripped.prefix(4_000))
    }

    private static func extractLinks(from html: String, limit: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?is)href\\s*=\\s*[\"']([^\"']+)[\"']") else {
            return []
        }
        let nsrange = NSRange(html.startIndex..<html.endIndex, in: html)
        var links: [String] = []
        regex.enumerateMatches(in: html, options: [], range: nsrange) { match, _, stop in
            guard let match,
                  let range = Range(match.range(at: 1), in: html) else {
                return
            }
            links.append(String(html[range]))
            if links.count >= max(1, limit) {
                stop.pointee = true
            }
        }
        return links
    }
}
