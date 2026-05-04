import Foundation
import CommonCrypto
import SQLite3

// MARK: - Ollama Cloud HTML Scraper

/// Scrapes Ollama Cloud usage data from `ollama.com/settings` using browser cookies.
///
/// Ollama Cloud has no public billing API. CodexBar's approach (verified working):
/// 1. Extract session cookies from Chrome (reuses FactoryCookieExtractor's decryption)
/// 2. GET https://ollama.com/settings with Cookie header
/// 3. Parse HTML for usage blocks:
///    - "Cloud Usage" → plan name
///    - "Session usage" / "Hourly usage" → usage % + reset time
///    - "Weekly usage" → weekly usage % + reset time
/// 4. Return `.exact` ProviderQuotaSnapshot
///
/// Reference: CodexBar `OllamaUsageFetcher.swift` + `OllamaUsageParser.swift`
/// (github.com/steipete/CodexBar, verified 2026-05-02)

enum OllamaCloudScraper {

    // MARK: - Public API

    struct CloudUsage: Sendable {
        let planName: String?
        let sessionUsedPercent: Double
        let weeklyUsedPercent: Double?
        let sessionResetsAt: Date?
        let weeklyResetsAt: Date?
        let accountEmail: String?
    }

    /// Attempt to scrape Ollama Cloud usage. Returns nil without valid cookies.
    static func fetchCloudUsage(session: URLSession = .shared) async -> CloudUsage? {
        guard let cookieHeader = extractOllamaCookieHeader(),
              let html = await fetchSettingsHTML(cookieHeader: cookieHeader, session: session) else {
            return nil
        }
        return parseCloudUsage(html: html)
    }

    /// Cookie header for ollama.com (for debugging)
    static func extractCookieHeader() -> String? {
        extractOllamaCookieHeader()
    }

    // MARK: - Cookie Extraction (reuses FactoryCookieExtractor's Chrome decryption)

    private static let ollamaSessionCookieNames: Set<String> = [
        "session", "__Secure-session", "ollama_session",
        "__Host-ollama_session", "__Secure-next-auth.session-token",
        "next-auth.session-token",
    ]

    private static func extractOllamaCookieHeader() -> String? {
        // Reuses the same Chrome cookie decryption as FactoryCookieExtractor.
        // The shared key derivation and AES-CBC decryption is in FactoryCookieExtractor.
        // Here we just query for ollama.com cookies specifically.
        return ChromeCookieReader.readCookies(
            domain: "ollama.com",
            matching: { name in
                ollamaSessionCookieNames.contains(name)
                    || name.hasPrefix("__Secure-next-auth.session-token.")
                    || name.hasPrefix("next-auth.session-token.")
            }
        )?.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
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

    // MARK: - HTML Parsing (matches CodexBar OllamaUsageParser.swift)

    private struct UsageBlock {
        let usedPercent: Double
        let resetsAt: Date?
    }

    private static func parseCloudUsage(html: String) -> CloudUsage {
        let planName = parsePlanName(html)
        let email = parseAccountEmail(html)
        let session = parseSessionUsage(html)
        let weekly = parseWeeklyUsage(html)

        return CloudUsage(
            planName: planName,
            sessionUsedPercent: session?.usedPercent ?? 0,
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
        for label in ["Session usage", "Hourly usage"] {
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
        let window = String(tail.prefix(800))
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

// MARK: - Shared Chrome Cookie Reader

/// Minimal Chrome cookie reader shared by OllamaCloudScraper and FactoryCookieExtractor.
/// Extracts and decrypts cookies for a specific domain from all Chrome profiles.
enum ChromeCookieReader {
    struct Cookie {
        let name: String
        let value: String
        let domain: String
    }

    /// Reads Chrome cookies for a domain, filtered by a name predicate.
    static func readCookies(domain: String, matching: (String) -> Bool) -> [Cookie]? {
        #if canImport(CommonCrypto) && canImport(SQLite3) && canImport(Security)
        guard let key = deriveKey() else { return nil }
        let chromeBase = ("~/Library/Application Support/Google/Chrome" as NSString).expandingTildeInPath

        guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: chromeBase) else { return nil }

        for profile in profiles.sorted(by: { a, _ in a == "Default" }) {
            let dbPath = "\(chromeBase)/\(profile)/Cookies"
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            guard let cookies = readCookies(dbPath: dbPath, key: key, domain: domain, matching: matching),
                  !cookies.isEmpty else { continue }
            return cookies
        }
        #endif
        return nil
    }

    #if canImport(CommonCrypto) && canImport(SQLite3) && canImport(Security)
    private static func deriveKey() -> Data? {
        var pwLen: UInt32 = 0
        var pwData: UnsafeMutableRawPointer?
        let service = "Chrome Safe Storage"
        let account = "Chrome"
        guard SecKeychainFindGenericPassword(nil, UInt32(service.utf8.count), service,
                UInt32(account.utf8.count), account, &pwLen, &pwData, nil) == errSecSuccess,
              let d = pwData, pwLen > 0 else { return nil }
        defer { SecKeychainItemFreeContent(nil, d) }
        let pw = Data(bytes: d, count: Int(pwLen))
        let salt = "saltysalt".data(using: .utf8)!
        var key = Data(count: 16)
        _ = key.withUnsafeMutableBytes { k in
            pw.withUnsafeBytes { p in salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    p.baseAddress?.assumingMemoryBound(to: Int8.self), pw.count,
                    s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                    k.baseAddress?.assumingMemoryBound(to: UInt8.self), 16)
            }}
        }
        return key
    }

    private static func readCookies(dbPath: String, key: Data, domain: String, matching: (String) -> Bool) -> [Cookie]? {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let database = db else { return nil }
        defer { sqlite3_close(database) }

        let query = "SELECT host_key, name, encrypted_value FROM cookies WHERE host_key LIKE '%\(domain)'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return nil }
        defer { sqlite3_finalize(s) }

        let iv = Data(repeating: 0x20, count: 16)
        var cookies: [Cookie] = []

        while sqlite3_step(s) == SQLITE_ROW {
            guard let hostPtr = sqlite3_column_text(s, 0),
                  let namePtr = sqlite3_column_text(s, 1),
                  let blob = sqlite3_column_blob(s, 2) else { continue }
            let host = String(cString: hostPtr)
            let name = String(cString: namePtr)
            let len = Int(sqlite3_column_bytes(s, 2))
            guard len > 3, matching(name) else { continue }

            let enc = Data(bytes: blob.advanced(by: 3), count: len - 3)
            guard let dec = aesDecrypt(enc, key: key, iv: iv), dec.count > 32 else { continue }
            let val = dec.dropFirst(32)
            guard let value = String(data: val, encoding: .utf8), !value.isEmpty else { continue }
            cookies.append(Cookie(name: name, value: value, domain: host))
        }
        return cookies.isEmpty ? nil : cookies
    }

    private static func aesDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        var buf = Data(count: data.count + kCCBlockSizeAES128)
        let bufferCapacity = buf.count
        var len: Int = 0
        let r = key.withUnsafeBytes { k in iv.withUnsafeBytes { i in
            data.withUnsafeBytes { d in buf.withUnsafeMutableBytes { b in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    k.baseAddress, key.count, i.baseAddress, d.baseAddress, data.count,
                    b.baseAddress, bufferCapacity, &len)
            }}}
        }
        guard r == kCCSuccess, len > 0 else { return nil }
        return buf.prefix(len)
    }
    #endif
}
