import Foundation

// MARK: - Warp GraphQL API Fetcher

/// Fetches real Warp AI request credit data from the Warp GraphQL API.
///
/// Ground truth source: `POST https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo`
/// with `Bearer wk-...` API key and required OS context headers.
///
/// ## Auth flow
/// Warp uses API keys only — no browser-based OAuth. Users create `wk-` keys at
/// https://app.warp.dev and provide them via `WARP_API_KEY` or `WARP_TOKEN` env var.
/// The key is validated by calling the GraphQL endpoint; HTTP 401/403 means the key
/// is invalid or expired.
///
/// ## Rate limiting
/// Warp's GraphQL endpoint returns HTTP 429 unless:
/// - `User-Agent` matches `Warp/1.0`
/// - `x-warp-client-id`, `x-warp-os-category`, `x-warp-os-name`, `x-warp-os-version` are set
///
/// Docs: https://docs.warp.dev/reference/cli/api-keys
/// Reference: CodexBar (github.com/steipete/CodexBar) — `WarpUsageFetcher.swift`

enum WarpAPIFetcher {

    // MARK: - Types

    struct WarpCredits: Sendable, Equatable {
        /// Total request limit for the billing period.
        let requestLimit: Int
        /// Requests used since last refresh.
        let requestsUsed: Int
        /// Whether the plan is unlimited.
        let isUnlimited: Bool
        /// ISO 8601 date for when the period resets (optional).
        let nextRefreshTime: Date?
        /// Combined bonus credits remaining (user-level + workspace-level).
        let bonusCreditsRemaining: Int
        /// Combined bonus credits total (user-level + workspace-level).
        let bonusCreditsTotal: Int
    }

    // MARK: - Configuration

    private static let timeoutInterval: TimeInterval = 15
    private static let apiURL = URL(string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!
    private static let clientID = "warp-app"
    /// Warp's GraphQL endpoint returns HTTP 429 unless User-Agent matches the official client pattern.
    private static let userAgent = "Warp/1.0"

    /// GraphQL query matching Warp's official client schema (verified against CodexBar).
    /// Queries user-level requestLimitInfo + bonusGrants, plus workspace-level bonusGrants.
    private static let graphQLQuery = """
    query GetRequestLimitInfo($requestContext: RequestContext!) {
      user(requestContext: $requestContext) {
        __typename
        ... on UserOutput {
          user {
            requestLimitInfo {
              isUnlimited
              nextRefreshTime
              requestLimit
              requestsUsedSinceLastRefresh
            }
            bonusGrants {
              requestCreditsGranted
              requestCreditsRemaining
              expiration
            }
            workspaces {
              bonusGrantsInfo {
                grants {
                  requestCreditsGranted
                  requestCreditsRemaining
                  expiration
                }
              }
            }
          }
        }
      }
    }
    """

    // MARK: - Public API

    /// Fetches Warp credit data using the provided API key.
    ///
    /// - Parameters:
    ///   - apiKey: Warp API key (typically starts with `wk-`).
    ///   - session: URLSession to use for the request.
    /// - Returns: Parsed credit data.
    /// - Throws: `QuotaServiceError` on HTTP or parsing failures.
    static func fetchCredits(
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> WarpCredits {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw QuotaServiceError.invalidResponse("Warp API key is empty.")
        }

        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutInterval
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue(clientID, forHTTPHeaderField: "x-warp-client-id")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-category")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-name")
        request.setValue(osVersionString, forHTTPHeaderField: "x-warp-os-version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let variables: [String: Any] = [
            "requestContext": [
                "clientContext": [:] as [String: Any],
                "osContext": [
                    "category": "macOS",
                    "name": "macOS",
                    "version": osVersionString,
                ] as [String: Any],
            ] as [String: Any],
        ]

        let body: [String: Any] = [
            "query": graphQLQuery,
            "variables": variables,
            "operationName": "GetRequestLimitInfo",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("Warp returned a non-HTTP response.")
        }

        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw QuotaServiceError.httpStatus(provider: .warp, code: http.statusCode)
        case 429:
            throw QuotaServiceError.invalidResponse("Warp rate-limited the request. Ensure User-Agent is set to Warp/1.0.")
        default:
            throw QuotaServiceError.httpStatus(provider: .warp, code: http.statusCode)
        }

        return try parseCreditsResponse(data)
    }

    /// Resolves a Warp API key from environment or keychain.
    ///
    /// Checks env vars in order: `WARP_API_KEY`, `WARP_TOKEN` — matching Warp's
    /// documented configuration (https://docs.warp.dev/reference/cli/api-keys).
    /// Falls back to resolved API keys in the keychain.
    static func resolveAPIKey(environment: [String: String], resolvedAPIKeys: [String: String?]) -> String? {
        // Warp-documented env vars
        for key in ["WARP_API_KEY", "WARP_TOKEN"] {
            if let envKey = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !envKey.isEmpty {
                return envKey
            }
        }
        // Keychain fallback
        for identifier in ["warp", "Warp"] {
            if let stored = resolvedAPIKeys[identifier] ?? nil,
               !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return stored
            }
        }
        return nil
    }

    // MARK: - Parsing

    /// Parses the GraphQL JSON response into `WarpCredits`.
    /// Package-private for testing.
    static func parseCreditsResponse(_ data: Data) throws -> WarpCredits {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaServiceError.invalidResponse("Warp response was not valid JSON.")
        }

        // Check for GraphQL errors
        if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { err -> String? in
                if let msg = err["message"] as? String { return msg }
                return nil
            }.joined(separator: "; ")
            throw QuotaServiceError.invalidResponse("Warp GraphQL error: \(messages)")
        }

        guard let dataDict = json["data"] as? [String: Any],
              let userObj = dataDict["user"] as? [String: Any] else {
            throw QuotaServiceError.invalidResponse("Warp response missing data.user.")
        }

        guard let innerUserObj = userObj["user"] as? [String: Any],
              let limitInfo = innerUserObj["requestLimitInfo"] as? [String: Any] else {
            throw QuotaServiceError.invalidResponse("Unable to extract requestLimitInfo from response.")
        }

        let isUnlimited = limitInfo["isUnlimited"] as? Bool ?? false
        let requestLimit = limitInfo["requestLimit"] as? Int ?? 0
        let requestsUsed = limitInfo["requestsUsedSinceLastRefresh"] as? Int ?? 0

        var nextRefreshTime: Date?
        if let nextRefreshTimeString = limitInfo["nextRefreshTime"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            nextRefreshTime = formatter.date(from: nextRefreshTimeString)
                ?? ISO8601DateFormatter().date(from: nextRefreshTimeString)
        }

        // Parse and combine bonus credits from user-level and workspace-level
        var bonusRemaining = 0
        var bonusTotal = 0
        if let bonusGrants = innerUserObj["bonusGrants"] as? [[String: Any]] {
            for grant in bonusGrants {
                bonusTotal += grant["requestCreditsGranted"] as? Int ?? 0
                bonusRemaining += grant["requestCreditsRemaining"] as? Int ?? 0
            }
        }
        if let workspaces = innerUserObj["workspaces"] as? [[String: Any]] {
            for workspace in workspaces {
                if let info = workspace["bonusGrantsInfo"] as? [String: Any],
                   let grants = info["grants"] as? [[String: Any]] {
                    for grant in grants {
                        bonusTotal += grant["requestCreditsGranted"] as? Int ?? 0
                        bonusRemaining += grant["requestCreditsRemaining"] as? Int ?? 0
                    }
                }
            }
        }

        guard isUnlimited || requestLimit > 0 || requestsUsed > 0 else {
            throw QuotaServiceError.invalidResponse(
                "Warp returned credit data but requestLimit is zero and plan is not unlimited."
            )
        }

        return WarpCredits(
            requestLimit: requestLimit,
            requestsUsed: requestsUsed,
            isUnlimited: isUnlimited,
            nextRefreshTime: nextRefreshTime,
            bonusCreditsRemaining: bonusRemaining,
            bonusCreditsTotal: bonusTotal
        )
    }
}
