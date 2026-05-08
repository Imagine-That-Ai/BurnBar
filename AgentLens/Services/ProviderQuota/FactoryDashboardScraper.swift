import Foundation

// MARK: - Factory Dashboard Scraper

/// Scrapes Factory usage data from the dashboard for personal (non-org) accounts.
///
/// Factory's billing API (`/api/organization/subscription/usage`) returns 403
/// for personal accounts that have no org subscription. But
/// `app.factory.ai/settings/billing` is a Next.js page that embeds usage
/// data in `__NEXT_DATA__` or renders it server-side. This scraper:
///
/// 1. Receives an OpenBurnBar-owned Factory session cookie header
/// 2. Fetches `app.factory.ai/settings/billing` as HTML
/// 3. Parses `__NEXT_DATA__` JSON for SSR props (plan, usage, limits)
/// 4. Falls back to regex-based HTML parsing for visible usage text
/// 5. Falls back to cookie-based API call for org accounts
///
/// Reference: CodexBar `OllamaUsageFetcher.swift` (same HTML scraping pattern).

enum FactoryDashboardScraper {

    // MARK: - Types

    struct DashboardUsage: Sendable {
        let planName: String?
        let tokensUsed: Double?
        let tokensLimit: Double?
        let usedPercent: Double?
        let periodEnd: Date?
        let accountEmail: String?
    }

    // MARK: - Public API

    /// Fetches personal usage by scraping the Factory dashboard HTML.
    /// Tries: __NEXT_DATA__ SSR props → regex HTML parsing → cookie-based API (org only).
    static func fetchPersonalUsage(cookieHeader: String?, session: URLSession = .shared) async -> DashboardUsage? {
        guard let cookieHeader = quotaNonEmpty(cookieHeader) else { return nil }
        // 1. Try HTML scraping of the billing dashboard page
        if let usage = await fetchDashboardHTML(cookieHeader: cookieHeader, session: session) {
            return usage
        }

        // 2. Try cookie-based API call (works for org accounts)
        if let usage = await fetchUsageViaAPI(cookieHeader: cookieHeader, session: session) {
            return usage
        }

        // 3. Try Bearer token API call
        if let bearer = FactoryCookieExtractor.extractBearerToken(from: cookieHeader),
           let usage = await fetchUsageViaBearer(bearer, session: session) {
            return usage
        }

        return nil
    }

    // MARK: - HTML Dashboard Scraping

    /// Fetches `app.factory.ai/settings/billing` and parses embedded usage data.
    /// Factory is a Next.js SPA; usage data may be in `__NEXT_DATA__` (SSR) or
    /// visible in rendered HTML text.
    private static func fetchDashboardHTML(
        cookieHeader: String,
        session: URLSession
    ) async -> DashboardUsage? {
        guard let url = URL(string: "https://app.factory.ai/settings/billing") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " +
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 15

        guard let (data, response) = try? await session.data(for: req),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        // Strategy 1: Parse __NEXT_DATA__ JSON (Next.js SSR props)
        if let usage = parseNextData(from: html) {
            return usage
        }

        // Strategy 2: Regex-based HTML parsing for visible usage text
        return parseDashboardHTML(html)
    }

    // MARK: - __NEXT_DATA__ Parsing

    private static func parseNextData(from html: String) -> DashboardUsage? {
        // Find <script id="__NEXT_DATA__" type="application/json">...</script>
        guard let startMarker = html.range(of: #""__NEXT_DATA__""#) ?? html.range(of: "__NEXT_DATA__"),
              let closeTag = html[startMarker.upperBound...].range(of: "</script>") else {
            return nil
        }

        let tailSection = html[startMarker.upperBound...]
        guard let jsonStart = tailSection.range(of: ">") else { return nil }
        let jsonStr = String(tailSection[jsonStart.upperBound..<closeTag.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !jsonStr.isEmpty,
              let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return nil
        }

        // Navigate: props → pageProps → ...
        let props = json["props"] as? [String: Any] ?? [:]
        let pageProps = props["pageProps"] as? [String: Any] ?? [:]

        // Try common Next.js data shapes
        let billing = pageProps["billing"] as? [String: Any]
            ?? pageProps["usage"] as? [String: Any]
            ?? pageProps["subscription"] as? [String: Any]
            ?? pageProps

        let planName = (billing["plan"] as? [String: Any])?["name"] as? String
            ?? billing["planName"] as? String
            ?? billing["tier"] as? String

        let tokensUsed = (billing["tokensUsed"] as? NSNumber)?.doubleValue
            ?? (billing["usage"] as? [String: Any]).flatMap { u in
                ((u["standard"] as? [String: Any])?["userTokens"] as? NSNumber)?.doubleValue
            }

        let tokensLimit = (billing["tokensLimit"] as? NSNumber)?.doubleValue
            ?? (billing["limit"] as? NSNumber)?.doubleValue

        let usedPercent: Double? = {
            if let pct = billing["usedPercent"] as? NSNumber {
                return pct.doubleValue
            }
            if let used = tokensUsed, let limit = tokensLimit, limit > 0 {
                return (used / limit) * 100
            }
            return nil
        }()

        let email = billing["email"] as? String
            ?? (pageProps["user"] as? [String: Any])?["email"] as? String

        guard tokensUsed != nil || usedPercent != nil || planName != nil else {
            return nil
        }

        return DashboardUsage(
            planName: planName,
            tokensUsed: tokensUsed,
            tokensLimit: tokensLimit,
            usedPercent: usedPercent,
            periodEnd: nil,
            accountEmail: email
        )
    }

    // MARK: - HTML Text Parsing (fallback)

    private static func parseDashboardHTML(_ html: String) -> DashboardUsage? {
        let planName = parseFactoryHTMLPlanName(html)
        let usage = parseFactoryHTMLUsage(html)
        let email = parseFactoryHTMLEmail(html)

        guard usage.tokensUsed != nil || usage.usedPercent != nil else {
            return nil
        }

        return DashboardUsage(
            planName: planName,
            tokensUsed: usage.tokensUsed,
            tokensLimit: usage.tokensLimit,
            usedPercent: usage.usedPercent,
            periodEnd: nil,
            accountEmail: email
        )
    }

    private static func parseFactoryHTMLPlanName(_ html: String) -> String? {
        for pattern in [
            #"Plan</[^>]+><[^>]+>([^<]+)<"#,
            #"(?:Pro|Team|Enterprise|Starter|Free|Hobby)"#
        ] {
            if let raw = firstCapture(in: html, pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private struct FactoryHTMLUsage {
        let tokensUsed: Double?
        let tokensLimit: Double?
        let usedPercent: Double?
    }

    private static func parseFactoryHTMLUsage(_ html: String) -> FactoryHTMLUsage {
        // Try percentage bar pattern: style="width: X%"
        if let pctStr = firstCapture(in: html, pattern: #"width:\s*([0-9]+(?:\.[0-9]+)?)%"#, options: [.caseInsensitive]),
           let pct = Double(pctStr) {
            return FactoryHTMLUsage(tokensUsed: nil, tokensLimit: nil, usedPercent: pct)
        }

        // Try "X% used" pattern
        if let pctStr = firstCapture(in: html, pattern: #"([0-9]+(?:\.[0-9]+)?)\s*%\s*used"#, options: [.caseInsensitive]),
           let pct = Double(pctStr) {
            return FactoryHTMLUsage(tokensUsed: nil, tokensLimit: nil, usedPercent: pct)
        }

        // Try token count: "X tokens" or "X / Y tokens"
        if let usedStr = firstCapture(in: html, pattern: #"([0-9,]+)\s*(?:/\s*([0-9,]+)\s*)?tokens"#, options: [.caseInsensitive]) {
            let parts = usedStr.components(separatedBy: "/").map { $0.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces) }
            let used = parts.count > 0 ? Double(parts[0]) : nil
            let limit = parts.count > 1 ? Double(parts[1]) : nil
            let pct: Double? = {
                if let u = used, let l = limit, l > 0 { return (u / l) * 100 }
                return nil
            }()
            return FactoryHTMLUsage(tokensUsed: used, tokensLimit: limit, usedPercent: pct)
        }

        return FactoryHTMLUsage(tokensUsed: nil, tokensLimit: nil, usedPercent: nil)
    }

    private static func parseFactoryHTMLEmail(_ html: String) -> String? {
        guard let raw = firstCapture(in: html, pattern: #"([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})"#, options: []) else {
            return nil
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Regex Helpers

    private static func firstCapture(in text: String, pattern: String, options: NSRegularExpression.Options) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captureRange])
    }

    // MARK: - Cookie-based API

    private static func fetchUsageViaAPI(
        cookieHeader: String,
        session: URLSession
    ) async -> DashboardUsage? {
        guard let url = URL(string: "https://api.factory.ai/api/organization/subscription/usage?useCache=true") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        req.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 10

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseUsageJSON(json)
    }

    // MARK: - Bearer Token API

    private static func fetchUsageViaBearer(
        _ bearer: String,
        session: URLSession
    ) async -> DashboardUsage? {
        guard let url = URL(string: "https://api.factory.ai/api/organization/subscription/usage?useCache=true") else {
            return nil
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        req.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 10

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return parseUsageJSON(json)
    }

    // MARK: - Response Parsing

    private static func parseUsageJSON(_ json: [String: Any]) -> DashboardUsage {
        let usage = json["usage"] as? [String: Any] ?? json
        let standard = usage["standard"] as? [String: Any]
        let premium = usage["premium"] as? [String: Any]

        let periodEnd: Date? = {
            let keys = ["endDate", "end_date"]
            for key in keys {
                if let ts = usage[key] as? String {
                    return ISO8601DateFormatter().date(from: ts)
                }
            }
            return nil
        }()

        let standardUsed = (standard?["userTokens"] as? NSNumber)?.doubleValue ?? 0
        let standardLimit = (standard?["totalAllowance"] as? NSNumber)?.doubleValue
        let premiumUsed = (premium?["userTokens"] as? NSNumber)?.doubleValue ?? 0

        let totalUsed = standardUsed + premiumUsed
        let usedPercent: Double? = {
            if let limit = standardLimit, limit > 0 {
                return (totalUsed / limit) * 100
            }
            return nil
        }()

        let planName = json["planName"] as? String
            ?? (json["organization"] as? [String: Any])?["name"] as? String

        return DashboardUsage(
            planName: planName,
            tokensUsed: totalUsed > 0 ? totalUsed : nil,
            tokensLimit: standardLimit,
            usedPercent: usedPercent,
            periodEnd: periodEnd,
            accountEmail: parseAccountEmail(from: json)
        )
    }

    private static func parseAccountEmail(from json: [String: Any]) -> String? {
        let candidates: [Any?] = [
            json["email"],
            json["accountEmail"],
            (json["user"] as? [String: Any])?["email"],
            (json["account"] as? [String: Any])?["email"],
            (json["organization"] as? [String: Any])?["email"],
        ]
        return candidates
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0.contains("@") }
    }
}
