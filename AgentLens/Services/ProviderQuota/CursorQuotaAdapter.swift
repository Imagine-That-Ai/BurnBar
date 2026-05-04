import Foundation

// MARK: - Cursor Quota Adapter

/// Fetches real Cursor usage/quota from `cursor.com/api/usage-summary`.
///
/// Ground truth source: `GET https://cursor.com/api/usage-summary` with
/// `Cookie: WorkosCursorSessionToken={userId}::{jwt}` header.
///
/// The session JWT and user ID are extracted from Cursor's own SQLite database
/// at `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`.
/// This database is always readable without Full Disk Access (unlike Safari's
/// binarycookies), making this a zero-config, zero-permission approach.
///
/// ## Resolution chain (first wins)
/// 1. `CURSOR_COOKIE_HEADER` environment variable
/// 2. Keychain-stored `cursor_cookie` value
/// 3. Auto-extract JWT from `state.vscdb` via `CursorCookieExtractor.readSession()`
/// 4. `CursorLoginHelper` — WKWebView login window (user signs in, cookies captured)
///
/// If no source yields a session: returns `confidence: .unavailable` (NOT estimated).
///
/// ## Data returned
/// - Primary bucket: "Included usage" — `totalPercentUsed` from plan usage
/// - Secondary bucket: "Auto + Composer" — `autoPercentUsed`
/// - API bucket: "API usage" — `apiPercentUsed`
/// - All values in cents divided by 100 for USD display
///
/// Reference: CodexBar `CursorStatusProbe.swift` — same endpoint, same cookie format.

struct CursorQuotaAdapter: ProviderQuotaAdapter {

    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        // 1. Try cookie header resolution (env → keychain → SQLite JWT → WKWebView login)
        if let credential = await resolveCursorCookieHeader(context: context) {
            do {
                let usageSummary = try await fetchCursorUsageSummary(
                    cookieHeader: credential.cookieHeader,
                    session: context.session
                )
                let userInfo = try? await fetchCursorUserInfo(
                    cookieHeader: credential.cookieHeader,
                    session: context.session
                )
                return buildExactSnapshot(
                    usageSummary: usageSummary,
                    userEmail: userInfo?.email,
                    cookieHeader: credential.cookieHeader
                )
            } catch {
                if credential.source == .configured, isAuthenticationRejection(error) {
                    return unavailableSnapshot(
                        statusMessage: "Cursor rejected the configured cookie. Update the Cursor cookie in Settings or sign in to Cursor again."
                    )
                }
                // If an auto-discovered cookie is invalid, try the next source.
            }
        }

        // 2. Try WKWebView login flow (opens cursor.com in a window, captures cookies)
        if !isAutoAuthDisabled(context: context),
           let cookieHeader = await CursorLoginHelper.runLoginFlow() {
            do {
                let usageSummary = try await fetchCursorUsageSummary(
                    cookieHeader: cookieHeader,
                    session: context.session
                )
                return buildExactSnapshot(
                    usageSummary: usageSummary,
                    userEmail: nil,
                    cookieHeader: cookieHeader
                )
            } catch {
                // Fall through to unavailable
            }
        }

        // No session available — return unavailable, NOT an estimate
        return unavailableSnapshot(
            statusMessage: "Sign in to Cursor to see usage. Open Cursor and sign in, or set CURSOR_COOKIE_HEADER in your environment."
        )
    }

    // MARK: - Credential Resolution

    private enum CursorCookieSource {
        case configured
        case extracted
    }

    private struct ResolvedCursorCookie {
        let cookieHeader: String
        let source: CursorCookieSource
    }

    private func resolveCursorCookieHeader(context: ProviderQuotaAdapterContext) async -> ResolvedCursorCookie? {
        // 1. Environment variable override (CURSOR_COOKIE_HEADER)
        if let envValue = context.environment["CURSOR_COOKIE_HEADER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envValue.isEmpty {
            return ResolvedCursorCookie(cookieHeader: envValue, source: .configured)
        }

        // 2. Stored API key (manual paste via Settings)
        if let rawStoredValue = context.resolvedAPIKeys["cursor_cookie"] ?? nil {
            let storedValue = rawStoredValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !storedValue.isEmpty {
                return ResolvedCursorCookie(cookieHeader: storedValue, source: .configured)
            }
        }

        guard !isAutoAuthDisabled(context: context) else {
            return nil
        }

        // 3. Auto-extract from Cursor's SQLite database (zero-config, no FDA needed)
        if let session = CursorCookieExtractor.readSession() {
            return ResolvedCursorCookie(cookieHeader: session.cookieHeader, source: .extracted)
        }

        return nil
    }

    private func isAutoAuthDisabled(context: ProviderQuotaAdapterContext) -> Bool {
        context.environment["OPENBURNBAR_DISABLE_CURSOR_AUTO_AUTH"] == "1"
    }

    private func isAuthenticationRejection(_ error: any Error) -> Bool {
        guard case let QuotaServiceError.httpStatus(provider, code) = error,
              provider == .cursor else {
            return false
        }
        return code == 401 || code == 403
    }

    private func unavailableSnapshot(statusMessage: String) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: .cursor,
            fetchedAt: Date(),
            source: .unavailable,
            confidence: .unavailable,
            managementURL: "https://cursor.com/dashboard",
            statusMessage: statusMessage,
            buckets: []
        )
    }

    // MARK: - API Calls

    private func fetchCursorUsageSummary(
        cookieHeader: String,
        session: URLSession
    ) async throws -> CursorUsageSummary {
        guard let url = URL(string: "https://cursor.sh/api/usage-summary") else {
            throw QuotaServiceError.invalidResponse("Cursor usage-summary URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Cursor returned a non-HTTP response.")
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw QuotaServiceError.httpStatus(provider: .cursor, code: http.statusCode)
        }

        guard (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.httpStatus(provider: .cursor, code: http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CursorUsageSummary.self, from: data)
    }

    private func fetchCursorUserInfo(
        cookieHeader: String,
        session: URLSession
    ) async throws -> CursorUserInfo {
        guard let url = URL(string: "https://cursor.sh/api/auth/me") else {
            throw QuotaServiceError.invalidResponse("Cursor auth URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.invalidResponse("Cursor user info request failed.")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CursorUserInfo.self, from: data)
    }

    // MARK: - Snapshot Building

    private func buildExactSnapshot(
        usageSummary: CursorUsageSummary,
        userEmail: String?,
        cookieHeader _: String
    ) -> ProviderQuotaSnapshot {
        var buckets: [ProviderQuotaBucket] = []

        let plan = usageSummary.individualUsage?.plan
        let onDemand = usageSummary.individualUsage?.onDemand

        // Parse billing cycle end
        let resetsAt = usageSummary.billingCycleEnd
            .flatMap { ISO8601DateFormatter().date(from: $0) }

        // Primary: Total included usage
        if let plan {
            let planUsed = Double(plan.used ?? 0) / 100.0
            let planLimit = Double(plan.limit ?? 0) / 100.0
            let totalPercent = plan.totalPercentUsed
                ?? plan.autoPercentUsed.map { a in
                    plan.apiPercentUsed.map { b in (a + b) / 2 } ?? a
                }

            if planLimit > 0 || planUsed > 0 {
                buckets.append(ProviderQuotaBucket(
                    key: "cursor-plan",
                    label: "Included usage",
                    windowKind: .monthly,
                    usedValue: planUsed,
                    limitValue: planLimit,
                    remainingValue: max(planLimit - planUsed, 0),
                    usedPercent: totalPercent,
                    resetsAt: resetsAt,
                    unit: .percent,
                    isEstimated: false
                ))
            }

            // Secondary: Auto + Composer
            if let autoPct = plan.autoPercentUsed, autoPct > 0 {
                buckets.append(ProviderQuotaBucket(
                    key: "cursor-auto",
                    label: "Auto + Composer",
                    windowKind: .monthly,
                    usedValue: autoPct,
                    limitValue: 100,
                    remainingValue: max(100 - autoPct, 0),
                    usedPercent: autoPct,
                    resetsAt: resetsAt,
                    unit: .percent,
                    isEstimated: false
                ))
            }

            // API usage
            if let apiPct = plan.apiPercentUsed, apiPct > 0 {
                buckets.append(ProviderQuotaBucket(
                    key: "cursor-api",
                    label: "API usage",
                    windowKind: .monthly,
                    usedValue: apiPct,
                    limitValue: 100,
                    remainingValue: max(100 - apiPct, 0),
                    usedPercent: apiPct,
                    resetsAt: resetsAt,
                    unit: .percent,
                    isEstimated: false
                ))
            }
        }

        // On-demand usage (separate from plan)
        if let onDemand, ((onDemand.used ?? 0) > 0 || (onDemand.limit ?? 0) > 0) {
            let odUsed = Double(onDemand.used ?? 0) / 100.0
            let odLimit = Double(onDemand.limit ?? 0) / 100.0
            if odUsed > 0 || odLimit > 0 {
                let odPct = odLimit > 0 ? (odUsed / odLimit) * 100 : 0.0
                buckets.append(ProviderQuotaBucket(
                    key: "cursor-ondemand",
                    label: "On-demand",
                    windowKind: .monthly,
                    usedValue: odUsed,
                    limitValue: odLimit,
                    remainingValue: odLimit > 0 ? max(odLimit - odUsed, 0) : nil,
                    usedPercent: odPct,
                    resetsAt: resetsAt,
                    unit: .count,
                    isEstimated: false
                ))
            }
        }

        let tier = usageSummary.membershipType?.capitalized ?? "Cursor"
        let emailSuffix = userEmail.map { " (\($0))" } ?? ""

        return ProviderQuotaSnapshot(
            provider: .cursor,
            fetchedAt: Date(),
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://cursor.com/dashboard",
            statusMessage: "\(tier)\(emailSuffix) — \(usageSummary.isUnlimited == true ? "Unlimited" : "Capped") plan.",
            buckets: buckets
        )
    }
}
