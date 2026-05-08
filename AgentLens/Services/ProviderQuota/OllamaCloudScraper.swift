import Foundation

// MARK: - Ollama Cloud HTML Scraper

/// Scrapes Ollama Cloud usage data from `ollama.com/settings` using an
/// OpenBurnBar-owned login session cookie header.
///
/// Ollama Cloud has no public billing API. OpenBurnBar preserves quota support
/// without reading third-party browser stores:
/// 1. User explicitly connects Ollama in OpenBurnBar's WKWebView login flow.
/// 2. OpenBurnBar stores the captured cookie header in its own Keychain.
/// 3. Refresh reads that app-owned session and fetches `ollama.com/settings`.
/// 4. Parse HTML for usage blocks:
///    - "Cloud Usage" -> plan name
///    - "Session usage" / "Hourly usage" -> usage % + reset time
///    - "Weekly usage" -> weekly usage % + reset time
/// 5. Return `.exact` ProviderQuotaSnapshot data.
///
/// Reference: CodexBar `OllamaUsageFetcher.swift` + `OllamaUsageParser.swift`
/// (github.com/steipete/CodexBar, verified 2026-05-02)

enum OllamaCloudScraper {

    // MARK: - Public API

    struct CloudUsage: Sendable {
        let planName: String?
        let sessionUsedPercent: Double?
        let weeklyUsedPercent: Double?
        let sessionResetsAt: Date?
        let weeklyResetsAt: Date?
        let accountEmail: String?
    }

    /// Attempts to scrape Ollama Cloud usage. Returns nil without a valid app-owned session.
    static func fetchCloudUsage(cookieHeader: String?, session: URLSession = .shared) async -> CloudUsage? {
        guard let cookieHeader = quotaNonEmpty(cookieHeader),
              let html = await fetchSettingsHTML(cookieHeader: cookieHeader, session: session) else {
            return nil
        }
        return parseCloudUsage(html: html)
    }

    /// Browser cookie auto-extraction is disabled by design.
    static func extractCookieHeader() -> String? {
        nil
    }

    // MARK: - HTML Fetching

    private static func fetchSettingsHTML(cookieHeader: String, session: URLSession) async -> String? {
        guard let url = URL(string: "https://ollama.com/settings") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://ollama.com", forHTTPHeaderField: "Origin")
        request.setValue("https://ollama.com", forHTTPHeaderField: "Referer")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - HTML Parsing

    private struct UsageBlock {
        let usedPercent: Double
        let resetsAt: Date?
    }

    static func parseCloudUsage(html: String) -> CloudUsage {
        let planName = parsePlanName(html)
        let email = parseAccountEmail(html)
        let session = parseSessionUsage(html)
        let weekly = parseWeeklyUsage(html)

        return CloudUsage(
            planName: planName,
            sessionUsedPercent: session?.usedPercent,
            weeklyUsedPercent: weekly?.usedPercent,
            sessionResetsAt: session?.resetsAt,
            weeklyResetsAt: weekly?.resetsAt,
            accountEmail: email)
    }

    private static func parsePlanName(_ html: String) -> String? {
        let pattern = #"Cloud Usage\s*</span>\s*<span[^>]*>([^<]+)</span>"#
        guard let raw = firstCapture(in: html, pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseAccountEmail(_ html: String) -> String? {
        let pattern = #"id=\"header-email\"[^>]*>([^<]+)<"#
        guard let raw = firstCapture(in: html, pattern: pattern, options: [.dotMatchesLineSeparators]),
              raw.contains("@") else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseSessionUsage(_ html: String) -> UsageBlock? {
        for label in ["5-hour usage", "5h usage", "Session usage", "Hourly usage"] {
            if let block = parseUsageBlock(label: label, html: html) { return block }
        }
        return nil
    }

    private static func parseWeeklyUsage(_ html: String) -> UsageBlock? {
        parseUsageBlock(label: "Weekly usage", html: html)
    }

    private static func parseUsageBlock(label: String, html: String) -> UsageBlock? {
        guard let labelRange = html.range(of: label) else { return nil }
        let tail = String(html[labelRange.upperBound...])
        let nextLabels = ["5-hour usage", "5h usage", "Session usage", "Hourly usage", "Weekly usage"]
            .filter { $0 != label }
        let nextLabelStart = nextLabels.compactMap { tail.range(of: $0)?.lowerBound }.min()
        let scopedTail = nextLabelStart.map { String(tail[..<$0]) } ?? tail
        let window = String(scopedTail.prefix(800))
        guard let usedPercent = parsePercent(in: window) else { return nil }
        return UsageBlock(usedPercent: usedPercent, resetsAt: parseISODate(in: window))
    }

    private static func parsePercent(in text: String) -> Double? {
        if let raw = firstCapture(in: text, pattern: #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#, options: [.caseInsensitive]) {
            return Double(raw)
        }
        if let raw = firstCapture(in: text, pattern: #"width:\s*([0-9]+(?:\.[0-9]+)?)%"#, options: [.caseInsensitive]) {
            return Double(raw)
        }
        return nil
    }

    private static func parseISODate(in text: String) -> Date? {
        guard let raw = firstCapture(in: text, pattern: #"data-time=\"([^\"]+)\""#, options: []) else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: raw)
    }

    private static func firstCapture(in text: String, pattern: String, options: NSRegularExpression.Options) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }
}
