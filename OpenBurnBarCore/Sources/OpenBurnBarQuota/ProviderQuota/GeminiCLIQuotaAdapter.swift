import Foundation
import OpenBurnBarKernel
import OpenBurnBarLogParsers

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Local Gemini CLI used-token meters.
///
/// Google does not publish remaining AI Studio RPD/RPM/TPM or consumer Gemini
/// app / Verizon Google AI Pro quota to an inference API key. This adapter
/// reports tokens actually written into `~/.gemini/tmp` session logs and keeps
/// remaining quota unavailable.
public struct GeminiCLIQuotaAdapter: ProviderQuotaAdapter {
    public init() {}

    public static let studioManagementURL = "https://aistudio.google.com"
    public static let consumerManagementURL = "https://gemini.google.com"
    public static let antigravityManagementURL = "https://antigravity.google"

    public func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        let geminiRoot = context.homeDirectoryURL.appendingPathComponent(".gemini", isDirectory: true)
        let authType = Self.readAuthType(root: geminiRoot, fileManager: context.fileManager)

        guard context.fileManager.fileExists(atPath: geminiRoot.path) else {
            return ProviderQuotaSnapshot(
                provider: .geminiCLI,
                fetchedAt: Date(),
                source: .unavailable,
                confidence: .unavailable,
                managementURL: Self.studioManagementURL,
                statusMessage: Self.statusMessage(
                    installed: false,
                    hasUsedTokens: false,
                    authType: authType
                ),
                buckets: []
            )
        }

        let tmpRoot = geminiRoot.appendingPathComponent("tmp", isDirectory: true)
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
                Self.usedOnlyBucket(
                    key: "tokens-24h",
                    label: "Tokens used in the last 24 hours",
                    windowKind: .rollingHours,
                    used: tokens24h
                ),
                Self.usedOnlyBucket(
                    key: "tokens-7d",
                    label: "Tokens used in the last 7 days",
                    windowKind: .rollingDays,
                    used: tokens7d
                )
            ]
            : []

        return ProviderQuotaSnapshot(
            provider: .geminiCLI,
            fetchedAt: now,
            source: hasUsedTokens ? .localSession : .unavailable,
            confidence: hasUsedTokens ? .exact : .unavailable,
            managementURL: authType == .oauthPersonal
                ? Self.consumerManagementURL
                : Self.studioManagementURL,
            statusMessage: Self.statusMessage(
                installed: true,
                hasUsedTokens: hasUsedTokens,
                authType: authType
            ),
            buckets: buckets
        )
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

    static func readAuthType(root: URL, fileManager: FileManager) -> DetectedAuthType {
        let settingsURL = root.appendingPathComponent("settings.json")
        guard fileManager.fileExists(atPath: settingsURL.path),
              let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(GeminiSettingsFile.self, from: data) else {
            return .unknown
        }

        let selected = [
            settings.selectedAuthType,
            settings.security?.auth?.selectedType,
            settings.security?.selectedType
        ].lazy.compactMap(stringValue).first ?? ""

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

    private static func stringValue(_ raw: String?) -> String? {
        guard let text = raw else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func statusMessage(
        installed: Bool,
        hasUsedTokens: Bool,
        authType: DetectedAuthType
    ) -> String {
        var parts: [String] = []
        if !installed {
            parts.append("Gemini CLI is not on this Mac.")
        } else if hasUsedTokens {
            parts.append("Token totals below come from Gemini CLI sessions on this Mac.")
        } else {
            parts.append("Gemini CLI is here, but there are no session tokens yet.")
        }
        parts.append("Google does not publish remaining AI Studio rate limits or Gemini app quota to other apps.")
        if authType == .oauthPersonal {
            parts.append("Personal Google login no longer serves Gemini CLI; use Antigravity for coding. Verizon / Gemini app remaining quota is not available.")
        }
        return parts.joined(separator: " ")
    }
}

/// Typed projection of `~/.gemini/settings.json`: only the auth-type
/// selectors are decoded, leniently (a value of an unexpected type, or a
/// non-object `security`/`auth`, reads as absent).
private struct GeminiSettingsFile: Decodable {
    struct Security: Decodable {
        struct Auth: Decodable {
            let selectedType: String?

            init(from decoder: Decoder) throws {
                selectedType = quotaLenientString(decoder, key: "selectedType")
            }
        }

        let auth: Auth?
        let selectedType: String?

        init(from decoder: Decoder) throws {
            auth = quotaLenientValue(Auth.self, decoder, key: "auth")
            selectedType = quotaLenientString(decoder, key: "selectedType")
        }
    }

    let selectedAuthType: String?
    let security: Security?

    init(from decoder: Decoder) throws {
        _ = try decoder.container(keyedBy: QuotaJSONKey.self)
        selectedAuthType = quotaLenientString(decoder, key: "selectedAuthType")
        security = quotaLenientValue(Security.self, decoder, key: "security")
    }
}
