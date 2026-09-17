import Foundation
import OpenBurnBarKernel
import OpenBurnBarLogParsers

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gemini CLI used-token meters plus Google Cloud remaining project quotas.
///
/// Phase 1: tokens written into `~/.gemini/tmp` session logs (used-only).
/// Phase 2: remaining Gemini API / Vertex rate-allocation quotas when ADC or
/// a service account can call Service Usage + Cloud Monitoring.
///
/// AI Studio `AIza…` keys, Firebase Google sign-in, and Verizon / Gemini app
/// subscriptions still have no remaining API. Those lanes stay explicitly
/// unsupported instead of inventing a battery.
public struct GeminiCLIQuotaAdapter: ProviderQuotaAdapter {
    public init() {}

    public static let studioManagementURL = "https://aistudio.google.com"
    public static let consumerManagementURL = "https://gemini.google.com"
    public static let antigravityManagementURL = "https://antigravity.google"
    public static let cloudQuotaURL = GoogleCloudQuotaClient.consoleURL

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let geminiRoot = context.homeDirectoryURL.appendingPathComponent(".gemini", isDirectory: true)
        let settings = Self.readSettings(root: geminiRoot, fileManager: context.fileManager)
        let authType = settings.authType
        let installed = context.fileManager.fileExists(atPath: geminiRoot.path)

        var usedBuckets: [ProviderQuotaBucket] = []
        var hasUsedTokens = false
        var parseError: String?
        if installed {
            do {
                let used = try await Self.loadUsedTokenBuckets(root: geminiRoot, context: context)
                usedBuckets = used.buckets
                hasUsedTokens = used.hasUsedTokens
            } catch {
                parseError = error.localizedDescription
            }
        }

        let cloud = await Self.loadCloudRemaining(
            context: context,
            extraProjectIDs: [settings.projectID].compactMap { $0 }
        )

        if !installed, usedBuckets.isEmpty, cloud == nil {
            return ProviderQuotaSnapshot(
                provider: .geminiCLI,
                fetchedAt: Date(),
                source: .unavailable,
                confidence: .unavailable,
                managementURL: Self.studioManagementURL,
                statusMessage: Self.statusMessage(
                    installed: false,
                    hasUsedTokens: false,
                    authType: authType,
                    cloud: nil,
                    parseError: parseError
                ),
                buckets: []
            )
        }

        if let parseError, usedBuckets.isEmpty, cloud == nil {
            throw QuotaServiceError.invalidResponse(parseError)
        }

        let remainingBuckets = cloud?.buckets ?? []
        let buckets = usedBuckets + remainingBuckets
        let hasRemaining = !remainingBuckets.isEmpty
        let source: ProviderQuotaSourceKind
        let confidence: ProviderQuotaConfidence
        if hasRemaining {
            source = .officialAPI
            confidence = .exact
        } else if hasUsedTokens {
            source = .localSession
            confidence = .exact
        } else {
            source = .unavailable
            confidence = .unavailable
        }

        let managementURL: String
        if hasRemaining {
            managementURL = Self.cloudQuotaURL
        } else if authType == .oauthPersonal {
            managementURL = Self.consumerManagementURL
        } else {
            managementURL = Self.studioManagementURL
        }

        return ProviderQuotaSnapshot(
            provider: .geminiCLI,
            fetchedAt: Date(),
            source: source,
            confidence: confidence,
            managementURL: managementURL,
            statusMessage: Self.statusMessage(
                installed: installed,
                hasUsedTokens: hasUsedTokens,
                authType: authType,
                cloud: cloud,
                parseError: parseError
            ),
            buckets: buckets
        )
    }

    static func loadUsedTokenBuckets(
        root: URL,
        context: ProviderQuotaAdapterContext
    ) async throws -> (buckets: [ProviderQuotaBucket], hasUsedTokens: Bool) {
        let tmpRoot = root.appendingPathComponent("tmp", isDirectory: true)
        let parser = GeminiCLIParser(
            logDirectoryOverride: tmpRoot.path,
            fileManager: context.fileManager,
            appPaths: context.appPaths
        )
        let parsed = try await parser.parse()
        let now = Date()
        let dayAgo = now.addingTimeInterval(-24 * 60 * 60)
        let weekAgo = now.addingTimeInterval(-7 * 24 * 60 * 60)

        var tokens24h = 0
        var tokens7d = 0
        for usage in parsed.usages {
            let total = usage.inputTokens + usage.outputTokens + usage.cacheReadTokens
            guard total > 0 else { continue }
            if usage.endTime >= weekAgo {
                tokens7d += total
            }
            if usage.endTime >= dayAgo {
                tokens24h += total
            }
        }

        let hasUsedTokens = tokens24h > 0 || tokens7d > 0
        let buckets: [ProviderQuotaBucket] = hasUsedTokens
            ? [
                usedOnlyBucket(
                    key: "tokens-24h",
                    label: "Tokens used in the last 24 hours",
                    windowKind: .rollingHours,
                    used: tokens24h
                ),
                usedOnlyBucket(
                    key: "tokens-7d",
                    label: "Tokens used in the last 7 days",
                    windowKind: .rollingDays,
                    used: tokens7d
                )
            ]
            : []
        return (buckets, hasUsedTokens)
    }

    static func loadCloudRemaining(
        context: ProviderQuotaAdapterContext,
        extraProjectIDs: [String]
    ) async -> GoogleCloudQuotaFetchResult? {
        switch await GoogleCloudQuotaCredentialResolver.resolve(
            context: context,
            extraProjectIDs: extraProjectIDs
        ) {
        case .success(let identity):
            return await GoogleCloudQuotaClient.fetchRemaining(
                identity: identity,
                session: context.session
            )
        case .failure(let error):
            if case .missing = error {
                return nil
            }
            return GoogleCloudQuotaFetchResult(
                buckets: [],
                statusMessage: error.statusMessage,
                projectID: extraProjectIDs.first ?? "",
                hadAPIError: true
            )
        }
    }

    static func usedOnlyBucket(
        key: String,
        label: String,
        windowKind: ProviderQuotaWindowKind,
        used: Int
    ) -> ProviderQuotaBucket {
        ProviderQuotaBucket(
            key: key,
            label: label,
            windowKind: windowKind,
            usedValue: Double(used),
            limitValue: nil,
            remainingValue: nil,
            usedPercent: nil,
            resetsAt: nil,
            unit: .tokens,
            isEstimated: false,
            limitKind: "used-only"
        )
    }

    enum DetectedAuthType: Equatable {
        case unknown
        case apiKey
        case oauthPersonal
        case vertex
    }

    struct DetectedSettings: Equatable {
        var authType: DetectedAuthType
        var projectID: String?
    }

    static func readSettings(root: URL, fileManager: FileManager) -> DetectedSettings {
        let settingsURL = root.appendingPathComponent("settings.json")
        guard fileManager.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return DetectedSettings(authType: .unknown, projectID: nil)
        }
        return DetectedSettings(
            authType: authType(from: object),
            projectID: GoogleCloudQuotaCredentialResolver.projectID(fromGeminiSettings: object)
        )
    }

    static func readAuthType(root: URL, fileManager: FileManager) -> DetectedAuthType {
        readSettings(root: root, fileManager: fileManager).authType
    }

    private static func authType(from object: [String: Any]) -> DetectedAuthType {
        var selected = stringValue(object["selectedAuthType"]) ?? ""
        if let security = object["security"] as? [String: Any] {
            if selected.isEmpty, let auth = security["auth"] as? [String: Any] {
                selected = stringValue(auth["selectedType"]) ?? ""
            }
            if selected.isEmpty {
                selected = stringValue(security["selectedType"]) ?? ""
            }
        }

        let normalized = selected.lowercased()
        if normalized.contains("oauth") || normalized.contains("personal") {
            return .oauthPersonal
        }
        if normalized.contains("vertex") || normalized.contains("adc") {
            return .vertex
        }
        if normalized.contains("gemini-api-key") || normalized.contains("api-key") || normalized.contains("apikey") {
            return .apiKey
        }
        return .unknown
    }

    private static func stringValue(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func statusMessage(
        installed: Bool,
        hasUsedTokens: Bool,
        authType: DetectedAuthType,
        cloud: GoogleCloudQuotaFetchResult? = nil,
        parseError: String? = nil
    ) -> String {
        var parts: [String] = []
        if !installed {
            parts.append("Gemini CLI is not on this Mac.")
        } else if hasUsedTokens {
            parts.append("Token totals below come from Gemini CLI sessions on this Mac.")
        } else {
            parts.append("Gemini CLI is here, but there are no session tokens yet.")
        }
        if let parseError, !parseError.isEmpty {
            parts.append("Local session parse failed: \(parseError).")
        }
        if let cloud, !cloud.buckets.isEmpty {
            parts.append(cloud.statusMessage)
        } else if let cloud {
            parts.append(cloud.statusMessage)
        } else if authType == .vertex {
            parts.append("Gemini CLI is using Vertex. Remaining project quotas need Application Default Credentials or a service account with Service Usage Consumer and Monitoring Viewer.")
        } else {
            parts.append("Google does not publish remaining AI Studio rate limits or Gemini app quota to an API key. Connect Google Cloud ADC or a service account to read project rate-quota remaining.")
        }
        if authType == .oauthPersonal {
            parts.append("Personal Google login no longer serves Gemini CLI; use Antigravity for coding. Verizon / Gemini app remaining quota is not available.")
        } else if cloud?.buckets.isEmpty != false {
            parts.append("Verizon / Gemini app remaining is not published.")
        }
        return parts.joined(separator: " ")
    }
}
