import OpenBurnBarCore
import Foundation

public typealias BurnBarBrowserFetcher = @Sendable (_ url: URL) async throws -> (Data, HTTPURLResponse)
public typealias BurnBarBrowserOpener = @Sendable (_ url: URL) throws -> Void
public typealias BurnBarExecutableLocator = @Sendable (_ executableName: String) -> String?

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
    private let logger: BurnBarDaemonLogger
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var cachedState: BurnBarStoredBrowserToolingFile?

    public init(
        fileURL: URL = BurnBarDaemonPaths.defaultBrowserToolingURL,
        fetcher: BurnBarBrowserFetcher? = nil,
        opener: BurnBarBrowserOpener? = nil,
        locateExecutable: BurnBarExecutableLocator? = nil,
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
            let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
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
            return BurnBarBrowserActionResponse(
                action: request.action,
                engine: engine,
                ok: false,
                summary: "Interactive browser actions are not available through this daemon browser service.",
                detail: "Use the Computer Use browser dispatcher for \(request.action.rawValue).",
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
            return executablePath == nil ? "Install Playwright CLI to expose future browser automation." : "Detected for future browser automation."
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
        case .playwright, .lightpanda:
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
