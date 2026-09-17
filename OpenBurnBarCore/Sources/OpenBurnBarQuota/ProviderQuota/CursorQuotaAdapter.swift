import Foundation
import OpenBurnBarKernel

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
/// Live URL: `GET https://cursor.sh/api/usage-summary` (docs also name cursor.com).
/// Limits come from the JSON (`plan.limit` cents ÷ 100). Do not hard-code $200/$400.
///
/// ## Resolution chain
/// Default seat:
/// 1. `CURSOR_COOKIE_HEADER` environment variable (debug / CI)
/// 2. Keychain-stored `cursor_cookie` value
/// 3. Auto-extract JWT from discovered `state.vscdb` installs, skipping expired JWTs
/// Extra seats (`OPENBURNBAR_QUOTA_ACCOUNT_ID` set): only that seat's cookie.
/// Refresh never opens a login window.
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

public struct CursorQuotaAdapter: ProviderQuotaAdapter {
    public init() {}

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        if let stored = configuredCookie(from: context),
           CursorMeterSeatPlanning.cookieHeaderIsExpired(stored) {
            return unavailableSnapshot(
                statusMessage: "Cursor signed this seat out. Reconnect to refresh the meter."
            )
        }

        // Cookie resolution (env / seat keychain / matching editor JWT). Never opens login.
        if let credential = await resolveCursorCookieHeader(context: context) {
            do {
                let usageSummaryData = try await fetchCursorUsageSummaryData(
                    cookieHeader: credential.cookieHeader,
                    session: context.session
                )
                // try?-ok(optional email enrichment)
                let userInfo = try? await fetchCursorUserInfo(
                    cookieHeader: credential.cookieHeader,
                    session: context.session
                )
                return try parseUsageSnapshot(
                    usageSummaryData,
                    userEmail: userInfo?.email,
                    now: Date(),
                    environment: context.environment,
                    quotaLogger: context.quotaLogger
                )
            } catch {
                if credential.source == .configured, isAuthenticationRejection(error) {
                    return unavailableSnapshot(
                        statusMessage: "Cursor rejected this session. Reconnect Cursor to refresh the meter."
                    )
                }
                // If an auto-discovered cookie is invalid, try the next source.
            }
        }
        return unavailableSnapshot(
            statusMessage: extraSeatAccountID(from: context) == nil
                ? "Connect Cursor to see included usage and Ultra spend."
                : "Cursor signed this seat out. Reconnect to refresh the meter."
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
        let extraSeatID = extraSeatAccountID(from: context)

        if extraSeatID != nil {
            if let stored = configuredCookie(from: context) {
                return ResolvedCursorCookie(cookieHeader: stored, source: .configured)
            }
            return extractedCookieMatchingPinnedSeat(context: context)
        }

        // 1. Environment variable override (CURSOR_COOKIE_HEADER) — default seat only
        if let envValue = quotaNonEmpty(context.environment["CURSOR_COOKIE_HEADER"]) {
            return ResolvedCursorCookie(cookieHeader: envValue, source: .configured)
        }

        // 2. Stored default-seat cookie (Connect / paste)
        if let stored = configuredCookie(from: context) {
            return ResolvedCursorCookie(cookieHeader: stored, source: .configured)
        }

        guard !isAutoAuthDisabled(context: context) else {
            return nil
        }

        // 3. Auto-extract from discovered Cursor installs (unconfigured default only)
        if let session = CursorCookieExtractor.readSession() {
            return ResolvedCursorCookie(cookieHeader: session.cookieHeader, source: .extracted)
        }

        return nil
    }

    private func configuredCookie(from context: ProviderQuotaAdapterContext) -> String? {
        if let extraSeatID = extraSeatAccountID(from: context) {
            let account = CursorMeterSeatPlanning.cookieAccount(forSeatID: extraSeatID)
            if let seatCookie = quotaNonEmpty(context.resolvedAPIKeys[account] ?? nil) {
                return seatCookie
            }
        }
        return quotaNonEmpty(context.resolvedAPIKeys[CursorMeterSeat.defaultCookieAccount] ?? nil)
    }

    private func extraSeatAccountID(from context: ProviderQuotaAdapterContext) -> String? {
        guard let accountID = quotaNonEmpty(context.environment["OPENBURNBAR_QUOTA_ACCOUNT_ID"]),
              accountID != CursorMeterSeat.defaultSeatID else {
            return nil
        }
        return accountID
    }

    private func extractedCookieMatchingPinnedSeat(context: ProviderQuotaAdapterContext) -> ResolvedCursorCookie? {
        guard !isAutoAuthDisabled(context: context) else { return nil }
        guard let stored = configuredCookie(from: context),
              let workos = CursorMeterSeatPlanning.workosCookieValue(fromCookieHeader: stored) else {
            return nil
        }
        let pinned = CursorMeterSeat(
            seatID: extraSeatAccountID(from: context) ?? CursorMeterSeat.defaultSeatID,
            installLabel: "Cursor",
            userID: CursorMeterSeatPlanning.userID(fromWorkosValue: workos),
            email: nil,
            membershipType: nil,
            cookieHeader: stored,
            keychainAccount: CursorMeterSeat.defaultCookieAccount,
            sourcePath: nil
        )
        for discovered in CursorCookieExtractor.readAllSessions() {
            if CursorMeterSeatPlanning.matchesPinnedIdentity(
                sessionUserID: discovered.session.userId,
                sessionEmail: discovered.session.email,
                seat: pinned
            ) {
                return ResolvedCursorCookie(
                    cookieHeader: discovered.session.cookieHeader,
                    source: .extracted
                )
            }
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

    private func fetchCursorUsageSummaryData(
        cookieHeader: String,
        session: URLSession
    ) async throws -> Data {
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

        return data
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

    func parseUsageSnapshot(
        _ data: Data,
        userEmail: String?,
        now: Date,
        environment: [String: String],
        quotaLogger: any QuotaLogger
    ) throws -> ProviderQuotaSnapshot {
        try CursorQuotaDomainCoreAdapter.snapshot(
            payload: data,
            userEmail: userEmail,
            now: now,
            environment: environment,
            quotaLogger: quotaLogger
        ) {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let usageSummary = try decoder.decode(CursorUsageSummary.self, from: data)
            return buildExactSnapshot(usageSummary: usageSummary, userEmail: userEmail, now: now)
        }
    }

    private func buildExactSnapshot(
        usageSummary: CursorUsageSummary,
        userEmail: String?,
        now: Date
    ) -> ProviderQuotaSnapshot {
        var buckets: [ProviderQuotaBucket] = []

        let plan = usageSummary.individualUsage?.plan
        let onDemand = usageSummary.individualUsage?.onDemand

        // Parse billing cycle end
        let resetsAt = usageSummary.billingCycleEnd
            .flatMap { ThreadSafeISO8601DateFormatter.parseBasic($0) }

        // Primary: Total included usage
        if let plan {
            let planUsed = Double(plan.used ?? 0) / 100.0
            let planLimit = Double(plan.limit ?? 0) / 100.0
            let totalPercent = plan.totalPercentUsed
                ?? plan.autoPercentUsed.map { a in
                    plan.apiPercentUsed.map { b in (a + b) / 2 } ?? a
                }

            if planLimit > 0 || planUsed > 0 || totalPercent != nil {
                // The plan bucket reports dollars when limit > 0, percent otherwise.
                let planRemaining = planLimit > planUsed
                    ? max(planLimit - planUsed, 0)
                    : (totalPercent.map { max(100 - $0, 0) } ?? max(planLimit - planUsed, 0))
                buckets.append(ProviderQuotaBucket(
                    key: "cursor-plan",
                    label: "Included usage",
                    windowKind: .monthly,
                    usedValue: planLimit > 0 ? planUsed : (totalPercent ?? planUsed),
                    limitValue: planLimit > 0 ? planLimit : 100,
                    remainingValue: planRemaining,
                    usedPercent: totalPercent,
                    resetsAt: resetsAt,
                    unit: planLimit > 0 ? .currency : .percent,
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
        if let onDemand, (onDemand.used ?? 0) > 0 || (onDemand.limit ?? 0) > 0 {
            let odUsed = Double(onDemand.used ?? 0) / 100.0
            let odLimit = Double(onDemand.limit ?? 0) / 100.0
            if odUsed > 0 || odLimit > 0 {
                let odPct = odLimit > 0 ? (odUsed / odLimit) * 100 : 0.0
                // On-demand spend is always in dollars — flipping unit so the
                // gauge displays "$X.XX / $Y.YY" instead of a raw decimal.
                buckets.append(ProviderQuotaBucket(
                    key: "cursor-ondemand",
                    label: "On-demand",
                    windowKind: .monthly,
                    usedValue: odUsed,
                    limitValue: odLimit,
                    remainingValue: odLimit > 0 ? max(odLimit - odUsed, 0) : nil,
                    usedPercent: odPct,
                    resetsAt: resetsAt,
                    unit: .currency,
                    isEstimated: false
                ))
            }
        }

        let tier = usageSummary.membershipType?.capitalized ?? "Cursor"
        let emailSuffix = userEmail.map { " (\($0))" } ?? ""

        return ProviderQuotaSnapshot(
            provider: .cursor,
            fetchedAt: now,
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://cursor.com/dashboard",
            statusMessage: "\(tier)\(emailSuffix) — \(usageSummary.isUnlimited == true ? "Unlimited" : "Capped") plan.",
            buckets: buckets
        )
    }
}
