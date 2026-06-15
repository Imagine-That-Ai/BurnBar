import Foundation
import OpenBurnBarCore

// MARK: - Elder Wand Web Tools
//
// Self-contained `web_fetch` + `web_search` tool backend for the server-side
// Elder Wand fusion tool-loop (`ElderWandToolLoop`). Both panel models and the
// judge can call these tools, capped by `max_tool_calls`.
//
// `web_fetch` reuses the daemon's URLSession fetch posture (the same
// SSRF-safe `OpenBurnBarBrowserTargetPolicy` + redirect guard the browser
// subsystem uses) and returns stripped page text.
//
// `web_search` is quota-metered through the hosted callable when Firebase auth
// headers are present. Local Perplexity/Tavily environment keys remain as a
// development fallback only; production quota exhaustion never falls through to
// local keys.

/// Hosted callable auth and endpoint forwarded by the macOS app to the daemon
/// only when Elder Wand Fusion is active.
struct ElderWandHostedSearchConfig: Sendable, Equatable {
    static let firebaseAuthorizationHeader = "x-openburnbar-firebase-authorization"
    static let appCheckHeader = "x-openburnbar-firebase-appcheck"
    static let defaultEndpoint = URL(string: "https://us-central1-burnbar.cloudfunctions.net/performElderWandHostedSearch")!

    let endpoint: URL
    let firebaseAuthorization: String
    let appCheckToken: String?

    static func resolve(
        headers: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ElderWandHostedSearchConfig? {
        let authorization = headers[firebaseAuthorizationHeader]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let authorization, !authorization.isEmpty else { return nil }
        let appCheck = headers[appCheckHeader]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ElderWandHostedSearchConfig(
            endpoint: endpoint(environment: environment),
            firebaseAuthorization: authorization,
            appCheckToken: appCheck?.isEmpty == false ? appCheck : nil
        )
    }

    private static func endpoint(environment: [String: String]) -> URL {
        for key in ["BURNBAR_ELDER_WAND_HOSTED_SEARCH_URL", "ELDER_WAND_HOSTED_SEARCH_URL"] {
            if let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty,
               let url = URL(string: raw),
               url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" {
                return url
            }
        }
        return defaultEndpoint
    }
}

/// Which search provider `web_search` talks to, resolved from the environment.
enum ElderWandSearchBackend: Sendable, Equatable {
    /// Perplexity Search API (`https://api.perplexity.ai/search`). Key from
    /// `BURNBAR_PERPLEXITY_SEARCH_API_KEY`, `PERPLEXITY_SEARCH_API_KEY`, or
    /// `PERPLEXITY_API_KEY`.
    case perplexity(apiKey: String)
    /// Tavily Search API (`https://api.tavily.com`). Key from
    /// `BURNBAR_TAVILY_API_KEY` (or legacy `TAVILY_API_KEY`).
    case tavily(apiKey: String)
    /// No key configured — `web_search` degrades gracefully.
    case unavailable

    var isAvailable: Bool {
        switch self {
        case .perplexity, .tavily: return true
        case .unavailable: return false
        }
    }

    /// Resolve the primary backend from a process environment. Perplexity wins
    /// when multiple keys are present; Tavily is fallback.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ElderWandSearchBackend {
        resolveAll(environment: environment).first ?? .unavailable
    }

    static func resolveAll(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [ElderWandSearchBackend] {
        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !raw.isEmpty {
                    return raw
                }
            }
            return nil
        }
        var backends: [ElderWandSearchBackend] = []
        if let key = value(["BURNBAR_PERPLEXITY_SEARCH_API_KEY", "PERPLEXITY_SEARCH_API_KEY", "PERPLEXITY_API_KEY"]) {
            backends.append(.perplexity(apiKey: key))
        }
        if let key = value(["BURNBAR_TAVILY_API_KEY", "TAVILY_API_KEY"]) {
            backends.append(.tavily(apiKey: key))
        }
        return backends
    }
}

/// One tool the fusion tool-loop can expose to a model: its OpenAI-shape
/// schema plus the closure that runs it. Kept value-typed and `Sendable` so it
/// survives `withThrowingTaskGroup` fan-out across panel members.
struct ElderWandTool: Sendable {
    /// Tool name as advertised in `tools[].function.name`.
    let name: String
    /// OpenAI `tools[]` schema entry for this tool, as a `Sendable`
    /// `BurnBarJSONValue` (the loop converts it to a Foundation object before
    /// serializing the model request body).
    let schema: BurnBarJSONValue
    /// Runs the tool given the raw JSON `arguments` string from the model.
    /// Returns plain text injected back as the `tool` message content. Must
    /// never throw — failures become a textual tool result so the loop keeps
    /// going.
    let invoke: @Sendable (_ arguments: String) async -> String
}

/// Builds the `web_fetch` + `web_search` tools backed by URLSession.
struct ElderWandWebTools: Sendable {
    private let hostedSearch: ElderWandHostedSearchConfig?
    private let searchBackends: [ElderWandSearchBackend]
    private let runID: String
    private let logger: BurnBarDaemonLogger
    /// Injectable fetcher so the SSRF + strip path is unit-testable without
    /// real network. Defaults to the same posture as the browser subsystem.
    private let fetcher: @Sendable (URL) async throws -> (Data, HTTPURLResponse)
    /// Injectable raw search request runner (returns JSON data) so the search
    /// path is unit-testable. Defaults to a plain URLSession call.
    private let searchRunner: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(
        hostedSearch: ElderWandHostedSearchConfig? = nil,
        searchBackend: ElderWandSearchBackend? = nil,
        runID: String = "elder-wand-\(UUID().uuidString)",
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "elder-wand-web-tools"),
        fetcher: (@Sendable (URL) async throws -> (Data, HTTPURLResponse))? = nil,
        searchRunner: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.hostedSearch = hostedSearch
        self.searchBackends = searchBackend.map { [$0] } ?? ElderWandSearchBackend.resolveAll()
        self.runID = runID
        self.logger = logger
        self.fetcher = fetcher ?? { url in
            let delegate = BurnBarBrowserRedirectGuard()
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, httpResponse)
        }
        self.searchRunner = searchRunner ?? { request in
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, httpResponse)
        }
    }

    /// The tools to advertise to a model. `web_search` is always listed (so the
    /// model can choose to try it), but it degrades gracefully when no key is
    /// configured.
    func makeTools() -> [ElderWandTool] {
        [makeWebFetchTool(), makeWebSearchTool()]
    }

    // MARK: - web_fetch

    private func makeWebFetchTool() -> ElderWandTool {
        let schema: BurnBarJSONValue = .object([
            "type": .string("function"),
            "function": .object([
                "name": .string("web_fetch"),
                "description": .string(
                    "Fetch a single http(s) web page and return its visible text content. "
                    + "Use this to read a specific URL (for example one returned by web_search)."
                ),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "url": .object([
                            "type": .string("string"),
                            "description": .string("The absolute http(s) URL to fetch.")
                        ])
                    ]),
                    "required": .array([.string("url")])
                ])
            ])
        ])
        let fetcher = self.fetcher
        let logger = self.logger
        return ElderWandTool(name: "web_fetch", schema: schema) { arguments in
            guard let rawURL = Self.stringArgument("url", from: arguments),
                  !rawURL.isEmpty else {
                return "web_fetch error: missing required \"url\" argument."
            }
            let url: URL
            do {
                url = try OpenBurnBarBrowserTargetPolicy.validatedResolvedURL(rawURL)
            } catch {
                return "web_fetch error: \(error.localizedDescription)"
            }
            do {
                let (data, response) = try await fetcher(url)
                guard (200..<300).contains(response.statusCode) else {
                    return "web_fetch error: HTTP \(response.statusCode) for \(url.absoluteString)."
                }
                let html = String(decoding: data, as: UTF8.self)
                let title = Self.extractTitle(from: html)
                let text = Self.stripHTML(html) ?? "(no readable text)"
                let header = title.map { "Title: \($0)\n" } ?? ""
                return "\(header)URL: \(url.absoluteString)\n\n\(text)"
            } catch {
                logger.silentFailure("elder_wand_web_fetch", error: error, context: ["url": url.absoluteString])
                return "web_fetch error: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - web_search

    private func makeWebSearchTool() -> ElderWandTool {
        let schema: BurnBarJSONValue = .object([
            "type": .string("function"),
            "function": .object([
                "name": .string("web_search"),
                "description": .string(
                    "Search the web for current information and return a ranked list of "
                    + "result titles, URLs, and snippets. Follow up with web_fetch to read "
                    + "a specific result in full."
                ),
                "parameters": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("The search query.")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ])
            ])
        ])
        let hostedSearch = self.hostedSearch
        let backends = self.searchBackends.filter(\.isAvailable)
        let runner = self.searchRunner
        let logger = self.logger
        let runID = self.runID
        return ElderWandTool(name: "web_search", schema: schema) { arguments in
            guard let query = Self.stringArgument("query", from: arguments)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                return "web_search error: missing required \"query\" argument."
            }
            if let hostedSearch {
                do {
                    return try await Self.runHostedSearch(
                        config: hostedSearch,
                        query: query,
                        runID: runID,
                        runner: runner
                    )
                } catch {
                    logger.silentFailure("elder_wand_hosted_web_search", error: error)
                    return Self.hostedSearchUnavailableMessage()
                }
            }
            guard !backends.isEmpty else {
                return "web_search unavailable: hosted live search quota/auth is unavailable and no local development search key is configured. "
                    + "Proceed using your own knowledge and any pages you can reach with web_fetch."
            }
            var providerErrors: [String] = []
            for backend in backends {
                do {
                    let request = try Self.makeSearchRequest(backend: backend, query: query)
                    let (data, response) = try await runner(request)
                    guard (200..<300).contains(response.statusCode) else {
                        providerErrors.append("HTTP \(response.statusCode)")
                        continue
                    }
                    let results = Self.parseSearchResults(backend: backend, data: data)
                    guard !results.isEmpty else {
                        providerErrors.append("no results")
                        continue
                    }
                    let rendered = results.prefix(8).enumerated().map { index, result in
                        "\(index + 1). \(result.title)\n   \(result.url)\n   \(result.snippet)"
                    }.joined(separator: "\n")
                    return "web_search results for \"\(query)\":\n\(rendered)"
                } catch {
                    providerErrors.append(error.localizedDescription)
                    logger.silentFailure("elder_wand_web_search", error: error)
                }
            }
            return "web_search error: all configured providers failed (\(providerErrors.prefix(3).joined(separator: "; ")))."
        }
    }

    private struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    private static func runHostedSearch(
        config: ElderWandHostedSearchConfig,
        query: String,
        runID: String,
        runner: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> String {
        let request = try makeHostedSearchRequest(config: config, query: query, runID: runID)
        let (data, response) = try await runner(request)
        guard (200..<300).contains(response.statusCode) else {
            return hostedSearchUnavailableMessage(data: data, statusCode: response.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return hostedSearchUnavailableMessage()
        }
        if root["error"] is [String: Any] {
            return hostedSearchUnavailableMessage(data: data, statusCode: response.statusCode)
        }
        let resultObject = (root["result"] as? [String: Any]) ?? root
        let provider = (resultObject["provider"] as? String) ?? "hosted"
        let rawResults = (resultObject["results"] as? [[String: Any]]) ?? []
        let results = parseHostedSearchResults(rawResults)
        guard !results.isEmpty else {
            return "web_search: no hosted results for \"\(query)\"."
        }
        let rendered = results.prefix(5).enumerated().map { index, result in
            "\(index + 1). \(result.title)\n   \(result.url)\n   \(result.snippet)"
        }.joined(separator: "\n")
        let quota = hostedQuotaLine(from: resultObject["quota"])
        return "web_search hosted results via \(provider) for \"\(query)\":\n\(rendered)\(quota)"
    }

    private static func makeHostedSearchRequest(
        config: ElderWandHostedSearchConfig,
        query: String,
        runID: String
    ) throws -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.firebaseAuthorization, forHTTPHeaderField: "Authorization")
        if let appCheckToken = config.appCheckToken {
            request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "data": [
                "query": query,
                "sessionId": runID,
                "runId": runID,
                "maxResults": 5,
                "runSearchCap": 12
            ]
        ])
        return request
    }

    private static func hostedSearchUnavailableMessage(data: Data? = nil, statusCode: Int? = nil) -> String {
        let detail: String
        if let data,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            detail = " \(String(message.prefix(180)))"
        } else if let statusCode {
            detail = " Hosted callable returned HTTP \(statusCode)."
        } else {
            detail = ""
        }
        return "web_search unavailable: hosted Fusion live-search quota is exhausted or unavailable.\(detail) Proceed without live web_search."
    }

    private static func parseHostedSearchResults(_ rawResults: [[String: Any]]) -> [SearchResult] {
        rawResults.compactMap { item in
            guard let url = item["url"] as? String,
                  url.starts(with: "http://") || url.starts(with: "https://") else {
                return nil
            }
            let rawTitle = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle?.isEmpty == false ? rawTitle ?? url : url
            let snippet = (item["snippet"] as? String)
                ?? (item["content"] as? String)
                ?? (item["description"] as? String)
                ?? ""
            return SearchResult(
                title: title,
                url: url,
                snippet: condense(snippet)
            )
        }
    }

    private static func hostedQuotaLine(from raw: Any?) -> String {
        guard let quota = raw as? [String: Any],
              let remaining = quota["remaining"] as? Int else {
            return ""
        }
        return "\nQuota: \(remaining) hosted Fusion searches remaining this month."
    }

    private static func makeSearchRequest(
        backend: ElderWandSearchBackend,
        query: String
    ) throws -> URLRequest {
        switch backend {
        case .perplexity(let apiKey):
            guard let url = URL(string: "https://api.perplexity.ai/search") else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let payload: [String: Any] = [
                "query": query,
                "max_results": 8
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return request
        case .tavily(let apiKey):
            guard let url = URL(string: "https://api.tavily.com/search") else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let payload: [String: Any] = [
                "query": query,
                "search_depth": "basic",
                "max_results": 8
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            return request
        case .unavailable:
            throw URLError(.userAuthenticationRequired)
        }
    }

    private static func parseSearchResults(
        backend: ElderWandSearchBackend,
        data: Data
    ) -> [SearchResult] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        switch backend {
        case .perplexity:
            let results =
                (object["results"] as? [[String: Any]])
                ?? (object["search_results"] as? [[String: Any]])
                ?? []
            guard !results.isEmpty else { return [] }
            return results.compactMap { item in
                guard let url = item["url"] as? String else { return nil }
                let title = (item["title"] as? String) ?? url
                let snippet = (item["snippet"] as? String)
                    ?? (item["description"] as? String)
                    ?? (item["content"] as? String)
                    ?? ""
                return SearchResult(title: title, url: url, snippet: Self.condense(snippet))
            }
        case .tavily:
            guard let results = object["results"] as? [[String: Any]] else { return [] }
            return results.compactMap { item in
                guard let url = item["url"] as? String else { return nil }
                let title = (item["title"] as? String) ?? url
                let snippet = (item["content"] as? String) ?? ""
                return SearchResult(title: title, url: url, snippet: Self.condense(snippet))
            }
        case .unavailable:
            return []
        }
    }

    // MARK: - Argument + HTML helpers

    /// Extract a string argument from the model's raw JSON `arguments` blob.
    private static func stringArgument(_ key: String, from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object[key] as? String
    }

    private static func condense(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(280))
    }

    private static func extractTitle(from html: String) -> String? {
        guard let range = html.range(
            of: "(?is)<title[^>]*>(.*?)</title>",
            options: .regularExpression
        ) else {
            return nil
        }
        let fragment = String(html[range])
        let title = fragment
            .replacingOccurrences(of: "(?is)</?title[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func stripHTML(_ html: String) -> String? {
        let stripped = html
            .replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : String(stripped.prefix(6_000))
    }
}
