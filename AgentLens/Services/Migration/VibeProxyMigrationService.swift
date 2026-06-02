import Foundation

enum VibeProxyMigrationState: Equatable {
    case idle
    case scanning
    case ready
    case importing
    case completed(message: String)
    case error(message: String)

    var isBusy: Bool {
        switch self {
        case .scanning, .importing: return true
        default: return false
        }
    }
}

enum VibeProxyCredentialDisposition: Equatable, Sendable {
    case importable(providerID: String, authMethodID: String)
    case disabled
    case needsReconnect(reason: String)

    var isImportable: Bool {
        if case .importable = self { return true }
        return false
    }
}

struct VibeProxyCredentialRecord: Identifiable, Equatable, Sendable {
    let id: String
    let sourceFileName: String
    let sourceType: String
    let sourceLabel: String
    let redactedSecret: String
    let disposition: VibeProxyCredentialDisposition
    fileprivate let secret: String?

    var canImport: Bool { disposition.isImportable && secret?.isEmpty == false }

    var providerID: String? {
        guard case .importable(let providerID, _) = disposition else { return nil }
        return providerID
    }

    var authMethodID: String? {
        guard case .importable(_, let authMethodID) = disposition else { return nil }
        return authMethodID
    }

    static func == (lhs: VibeProxyCredentialRecord, rhs: VibeProxyCredentialRecord) -> Bool {
        lhs.id == rhs.id
            && lhs.sourceFileName == rhs.sourceFileName
            && lhs.sourceType == rhs.sourceType
            && lhs.sourceLabel == rhs.sourceLabel
            && lhs.redactedSecret == rhs.redactedSecret
            && lhs.disposition == rhs.disposition
    }
}

struct VibeProxyMigrationSnapshot: Equatable, Sendable {
    let authDirectoryURL: URL
    let credentialRecords: [VibeProxyCredentialRecord]
    let detectedTargets: [RoutingClientWiringTarget]

    var importableRecords: [VibeProxyCredentialRecord] {
        credentialRecords.filter(\.canImport)
    }

    var reconnectRecords: [VibeProxyCredentialRecord] {
        credentialRecords.filter {
            if case .needsReconnect = $0.disposition { return true }
            return false
        }
    }

    var disabledRecords: [VibeProxyCredentialRecord] {
        credentialRecords.filter {
            if case .disabled = $0.disposition { return true }
            return false
        }
    }

    var foundAnything: Bool {
        !credentialRecords.isEmpty || !detectedTargets.isEmpty
    }
}

struct VibeProxyCredentialImportRequest: Sendable {
    let providerID: String
    let label: String
    let apiKey: String
    let authMethodID: String
    let sourceFileName: String
}

struct VibeProxyMigrationImportResult: Equatable, Sendable {
    let imported: [String]
    let failed: [String: String]

    var importedCount: Int { imported.count }
    var failedCount: Int { failed.count }
}

struct VibeProxyMigrationService: Sendable {
    typealias CredentialImporter = @Sendable (VibeProxyCredentialImportRequest) async throws -> String

    private let fileManager: FileManager
    private let home: URL

    init(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.home = home
    }

    func scan() throws -> VibeProxyMigrationSnapshot {
        let authDirectoryURL = home.appendingPathComponent(".cli-proxy-api")
        let records = try scanCredentialRecords(in: authDirectoryURL)
        let targets = detectVibeProxyTargets()
        return VibeProxyMigrationSnapshot(
            authDirectoryURL: authDirectoryURL,
            credentialRecords: records,
            detectedTargets: targets
        )
    }

    func importCredentials(
        from snapshot: VibeProxyMigrationSnapshot,
        importer: CredentialImporter
    ) async -> VibeProxyMigrationImportResult {
        var imported: [String] = []
        var failed: [String: String] = [:]

        for record in snapshot.importableRecords {
            guard case .importable(let providerID, let authMethodID) = record.disposition,
                  let secret = record.secret?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !secret.isEmpty else {
                continue
            }

            do {
                _ = try await importer(
                    VibeProxyCredentialImportRequest(
                        providerID: providerID,
                        label: "VibeProxy \(record.sourceLabel)",
                        apiKey: secret,
                        authMethodID: authMethodID,
                        sourceFileName: record.sourceFileName
                    )
                )
                imported.append(record.id)
            } catch {
                failed[record.id] = error.localizedDescription
            }
        }

        return VibeProxyMigrationImportResult(imported: imported, failed: failed)
    }

    private func scanCredentialRecords(in directory: URL) throws -> [VibeProxyCredentialRecord] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        return urls.map { url in
            credentialRecord(from: url)
        }
    }

    private func credentialRecord(from url: URL) -> VibeProxyCredentialRecord {
        let fileName = url.lastPathComponent
        let fallbackLabel = url.deletingPathExtension().lastPathComponent

        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return VibeProxyCredentialRecord(
                id: fileName,
                sourceFileName: fileName,
                sourceType: "unknown",
                sourceLabel: fallbackLabel,
                redactedSecret: "",
                disposition: .needsReconnect(reason: "Could not parse this VibeProxy credential file."),
                secret: nil
            )
        }

        let type = stringValue(object, keys: ["type"])?.lowercased() ?? "unknown"
        let label = stringValue(object, keys: ["label", "email", "login", "provider"]) ?? fallbackLabel
        let secret = apiKeyValue(object)
        let disposition = disposition(
            sourceType: type,
            provider: stringValue(object, keys: ["provider", "providerID", "provider_id"]),
            secret: secret,
            disabled: boolValue(object, key: "disabled")
        )

        return VibeProxyCredentialRecord(
            id: "\(fileName):\(type):\(label)",
            sourceFileName: fileName,
            sourceType: type,
            sourceLabel: label,
            redactedSecret: redact(secret),
            disposition: disposition,
            secret: secret
        )
    }

    private func disposition(
        sourceType: String,
        provider: String?,
        secret: String?,
        disabled: Bool
    ) -> VibeProxyCredentialDisposition {
        if disabled { return .disabled }
        guard let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            return .needsReconnect(reason: "VibeProxy stores this account as a local login. Reconnect it in OpenBurnBar.")
        }

        let providerHint = provider ?? sourceType
        switch normalizedProviderID(providerHint) {
        case "zai":
            return .importable(providerID: "zai", authMethodID: "zai-coding-plan")
        case "anthropic":
            let method = secret.lowercased().hasPrefix("sk-ant-")
                ? "anthropic-api-key"
                : "anthropic-claude-oauth"
            return .importable(providerID: "anthropic", authMethodID: method)
        case "openai":
            guard secret.lowercased().hasPrefix("sk-") else {
                return .needsReconnect(reason: "ChatGPT/Codex OAuth sessions are local logins, not OpenAI API keys.")
            }
            return .importable(providerID: "openai", authMethodID: "openai-api-key")
        case "alibaba":
            return .importable(providerID: "alibaba", authMethodID: "alibaba-api-key")
        case "google":
            return .importable(providerID: "google", authMethodID: "google-api-key")
        case "xai":
            return .importable(providerID: "xai", authMethodID: "xai-api-key")
        case "minimax":
            let method = secret.lowercased().hasPrefix("sk-cp-")
                ? "minimax-coding-plan"
                : "minimax-open-platform"
            return .importable(providerID: "minimax", authMethodID: method)
        case "deepseek":
            return .importable(providerID: "deepseek", authMethodID: "deepseek-api-key")
        case "mistral":
            return .importable(providerID: "mistral", authMethodID: "mistral-api-key")
        case "ollama":
            return .importable(providerID: "ollama", authMethodID: "ollama-cloud-key")
        case "mimo":
            let method = secret.lowercased().hasPrefix("tp-") ? "mimo-token-plan" : "mimo-payg"
            return .importable(providerID: "mimo", authMethodID: method)
        case "moonshot":
            guard secret.lowercased().hasPrefix("sk-") else {
                return .needsReconnect(reason: "Kimi browser sessions need OpenBurnBar's guided reconnect so quota mirroring is set up correctly.")
            }
            return .importable(providerID: "moonshot", authMethodID: "moonshot-api-key")
        case "github-copilot", "antigravity", "codex", "gemini", "kimi":
            return .needsReconnect(reason: "This VibeProxy login is app-local OAuth or session state. Reconnect it in OpenBurnBar.")
        default:
            return .needsReconnect(reason: "OpenBurnBar does not recognize this VibeProxy provider yet.")
        }
    }

    private func detectVibeProxyTargets() -> [RoutingClientWiringTarget] {
        let wiring = RoutingClientWiring(fileManager: fileManager, home: home)
        return [.droid, .claudeCode, .codex, .opencode, .forge, .grok].filter { target in
            switch target {
            case .droid:
                return [
                    home.appendingPathComponent(".factory/settings.local.json"),
                    home.appendingPathComponent(".factory/settings.json"),
                    home.appendingPathComponent(".factory/config.json"),
                ].contains(where: fileLooksVibeProxyOwned)
            default:
                return fileLooksVibeProxyOwned(wiring.configURL(for: target))
            }
        }
    }

    private func fileLooksVibeProxyOwned(_ url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        let lowercased = text.lowercased()
        return lowercased.contains("vibeproxy")
            || lowercased.contains("cli-proxy-api")
            || lowercased.contains("http://localhost:8317")
            || lowercased.contains("http://127.0.0.1:8317")
    }

    private func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private func boolValue(_ object: [String: Any], key: String) -> Bool {
        if let bool = object[key] as? Bool { return bool }
        if let number = object[key] as? NSNumber { return number.boolValue }
        if let string = object[key] as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }

    private func apiKeyValue(_ object: [String: Any]) -> String? {
        stringValue(object, keys: ["api_key", "apiKey", "key"])
    }

    private func normalizedProviderID(_ raw: String) -> String {
        let normalized = raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        switch normalized {
        case "zai", "z-ai", "z.ai", "glm", "bigmodel":
            return "zai"
        case "anthropic", "claude", "claude-code":
            return "anthropic"
        case "openai", "chatgpt":
            return "openai"
        case "qwen", "dashscope", "alibaba":
            return "alibaba"
        case "google", "gemini":
            return "google"
        case "grok", "xai", "x-ai":
            return "xai"
        case "kimi", "moonshot", "moonshot.cn":
            return "moonshot"
        default:
            return normalized
        }
    }

    private func redact(_ secret: String?) -> String {
        guard let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty else {
            return ""
        }
        guard secret.count > 8 else { return "..." }
        return "\(secret.prefix(4))...\(secret.suffix(4))"
    }
}
