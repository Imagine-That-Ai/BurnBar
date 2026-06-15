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
// `web_search` is a configurable HTTP backend (Brave or Tavily) keyed from the
// daemon environment. When NO key is configured the tool returns a graceful
// "search unavailable" tool result instead of crashing — the model simply
// proceeds without web search.

/// Which search provider `web_search` talks to, resolved from the environment.
enum ElderWandSearchBackend: Sendable, Equatable {
    /// Brave Search API (`https://api.search.brave.com`). Key from
    /// `BURNBAR_BRAVE_SEARCH_API_KEY` (or legacy `BRAVE_SEARCH_API_KEY`).
    case brave(apiKey: String)
    /// Tavily Search API (`https://api.tavily.com`). Key from
    /// `BURNBAR_TAVILY_API_KEY` (or legacy `TAVILY_API_KEY`).
    case tavily(apiKey: String)
    /// No key configured — `web_search` degrades gracefully.
    case unavailable

    var isAvailable: Bool {
        switch self {
        case .brave, .tavily: return true
        case .unavailable: return false
        }
    }

    /// Resolve the backend from a process environment. Brave wins when both
    /// keys are present (it is the cheaper/default backend).
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ElderWandSearchBackend {
        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !raw.isEmpty {
                    return raw
                }
            }
            return nil
        }
        if let key = value(["BURNBAR_BRAVE_SEARCH_API_KEY", "BRAVE_SEARCH_API_KEY"]) {
            return .brave(apiKey: key)
        }
        if let key = value(["BURNBAR_TAVILY_API_KEY", "TAVILY_API_KEY"]) {
            return .tavily(apiKey: key)
        }
        return .unavailable
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
    private let searchBackend: ElderWandSearchBackend
    private let logger: BurnBarDaemonLogger
    /// Injectable fetcher so the SSRF + strip path is unit-testable without
    /// real network. Defaults to the same posture as the browser subsystem.
    private let fetcher: @Sendable (URL) async throws -> (Data, HTTPURLResponse)
    /// Injectable raw search request runner (returns JSON data) so the search
    /// path is unit-testable. Defaults to a plain URLSession call.
    private let searchRunner: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(
        searchBackend: ElderWandSearchBackend = ElderWandSearchBackend.resolve(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "elder-wand-web-tools"),
        fetcher: (@Sendable (URL) async throws -> (Data, HTTPURLResponse))? = nil,
        searchRunner: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.searchBackend = searchBackend
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
        let backend = self.searchBackend
        let runner = self.searchRunner
        let logger = self.logger
        return ElderWandTool(name: "web_search", schema: schema) { arguments in
            guard backend.isAvailable else {
                return "web_search unavailable: no search provider API key is configured on this server. "
                    + "Proceed using your own knowledge and any pages you can reach with web_fetch."
            }
            guard let query = Self.stringArgument("query", from: arguments)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty else {
                return "web_search error: missing required \"query\" argument."
            }
            do {
                let request = try Self.makeSearchRequest(backend: backend, query: query)
                let (data, response) = try await runner(request)
                guard (200..<300).contains(response.statusCode) else {
                    return "web_search error: provider returned HTTP \(response.statusCode)."
                }
                let results = Self.parseSearchResults(backend: backend, data: data)
                guard !results.isEmpty else {
                    return "web_search: no results for \"\(query)\"."
                }
                let rendered = results.prefix(8).enumerated().map { index, result in
                    "\(index + 1). \(result.title)\n   \(result.url)\n   \(result.snippet)"
                }.joined(separator: "\n")
                return "web_search results for \"\(query)\":\n\(rendered)"
            } catch {
                logger.silentFailure("elder_wand_web_search", error: error)
                return "web_search error: \(error.localizedDescription)"
            }
        }
    }

    private struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    private static func makeSearchRequest(
        backend: ElderWandSearchBackend,
        query: String
    ) throws -> URLRequest {
        switch backend {
        case .brave(let apiKey):
            var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")
            components?.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "count", value: "8")
            ]
            guard let url = components?.url else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
            return request
        case .tavily(let apiKey):
            guard let url = URL(string: "https://api.tavily.com/search") else { throw URLError(.badURL) }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "api_key": apiKey,
                "query": query,
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
        case .brave:
            guard let web = object["web"] as? [String: Any],
                  let results = web["results"] as? [[String: Any]] else {
                return []
            }
            return results.compactMap { item in
                guard let url = item["url"] as? String else { return nil }
                let title = (item["title"] as? String) ?? url
                let snippet = (item["description"] as? String) ?? ""
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
