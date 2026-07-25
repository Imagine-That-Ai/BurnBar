import Foundation

extension RoutingClientWiring {

    /// Whether the helper currently sees the OpenBurnBar marker in the
    /// target's config file. Surfaces use this to render an accurate
    /// "wired / not wired" pill without having to track the toggle state
    /// in user defaults.
    func isWired(target: RoutingClientWiringTarget) -> Bool {
        let url = configURL(for: target)
        switch target {
        case .claudeCode:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false } // try?-ok(unreadable means not wired)
            if let root = try? readJSONObject(at: url), // try?-ok(malformed config falls back)
               let env = root["env"] as? [String: Any] {
                if env["OPENBURNBAR_WIRED"] != nil { return true }
                if let baseURL = env["ANTHROPIC_BASE_URL"] as? String,
                   isLocalGatewayURL(baseURL) {
                    return true
                }
            }
            return text.contains(Self.sentinelStart)
        case .opencode:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false } // try?-ok(unreadable means not wired)
            if let root = try? readJSONObject(at: url), // try?-ok(malformed config falls back)
               let providers = root["provider"] as? [String: Any],
               let provider = providers["openburnbar"] as? [String: Any] {
                if let options = provider["options"] as? [String: Any],
                   let baseURL = options["baseURL"] as? String,
                   isLocalGatewayURL(baseURL) {
                    return true
                }
                if let models = provider["models"] as? [String: Any], !models.isEmpty {
                    return true
                }
            }
            return text.contains("\"openburnbar\"") && text.localizedCaseInsensitiveContains("OpenBurnBar Gateway")
        case .droid:
            return droidConfigURLs().contains { url in
                guard fileManager.fileExists(atPath: url.path),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { // try?-ok(unreadable means not wired)
                    return false
                }
                if let root = try? readJSONObject(at: url) { // try?-ok(malformed config falls back)
                    let settingsModels = (root["customModels"] as? [[String: Any]]) ?? []
                    let configModels = (root["custom_models"] as? [[String: Any]]) ?? []
                    if (settingsModels + configModels).contains(where: { isOpenBurnBarDroidModel($0) }) {
                        return true
                    }
                }
                return (text.contains("\"customModels\"") || text.contains("\"custom_models\""))
                    && (text.localizedCaseInsensitiveContains("custom:OpenBurnBar")
                        || text.localizedCaseInsensitiveContains("openburnbar:")
                        || text.localizedCaseInsensitiveContains("OpenBurnBar "))
            }
        case .codex:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false } // try?-ok(unreadable means not wired)
            return text.contains(Self.sentinelStart)
                || (text.contains("[model_providers.openburnbar]") && text.contains("base_url") && text.contains(":8317"))
                || text.range(of: #"base_url\s*=\s*"https?://(127\.0\.0\.1|localhost):8317(/v1)?/?.*""#, options: .regularExpression) != nil
        case .forge:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false } // try?-ok(unreadable means not wired)
            return text.contains(Self.sentinelStart)
                || (text.contains(#"id = "openburnbar""#) && text.contains(":8317"))
                || text.range(of: #"url\s*=\s*"https?://(127\.0\.0\.1|localhost):8317(/v1)?/chat/completions""#, options: .regularExpression) != nil
        case .grok:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false } // try?-ok(unreadable means not wired)
            return text.contains(Self.sentinelStart)
                || (text.contains("[model.openburnbar]") && text.contains("base_url"))
        case .antigravity:
            return false
        case .cursorAgent:
            return false
        }
    }

    /// Returns true only when the target config carries an OpenBurnBar-owned
    /// marker. This is stricter than `isWired(...)`, which also accepts broad
    /// localhost gateway hints for UI status.
    func hasOpenBurnBarOwnershipMarker(target: RoutingClientWiringTarget) -> Bool {
        let url = configURL(for: target)
        switch target {
        case .claudeCode:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false } // try?-ok(unreadable means not OpenBurnBar-owned)
            if let root = try? readJSONObject(at: url), // try?-ok(malformed config falls back)
               let env = root["env"] as? [String: Any] {
                if env["OPENBURNBAR_WIRED"] != nil { return true }
                if env[Self.claudeCatalogIDsKey] != nil { return true }
                if env[Self.claudeCatalogFingerprintKey] != nil { return true }
                if let headers = env["ANTHROPIC_CUSTOM_HEADERS"] as? String,
                   headers.localizedCaseInsensitiveContains(Self.claudeCodeClientHeader) {
                    return true
                }
            }
            return text.contains(Self.sentinelStart)
        case .opencode:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false } // try?-ok(unreadable means not OpenBurnBar-owned)
            return text.contains("\"openburnbar\"") && text.localizedCaseInsensitiveContains("OpenBurnBar Gateway")
        case .droid:
            return droidConfigURLs().contains { url in
                guard fileManager.fileExists(atPath: url.path),
                      let text = try? String(contentsOf: url, encoding: .utf8) else { // try?-ok(unreadable means not OpenBurnBar-owned)
                    return false
                }
                if let root = try? readJSONObject(at: url) { // try?-ok(malformed config falls back)
                    let settingsModels = (root["customModels"] as? [[String: Any]]) ?? []
                    let configModels = (root["custom_models"] as? [[String: Any]]) ?? []
                    if (settingsModels + configModels).contains(where: { hasOpenBurnBarDroidOwnershipMarker($0) }) {
                        return true
                    }
                }
                return (text.contains("\"customModels\"") || text.contains("\"custom_models\""))
                    && (text.localizedCaseInsensitiveContains("custom:OpenBurnBar")
                        || text.localizedCaseInsensitiveContains("openburnbar:")
                        || text.localizedCaseInsensitiveContains("OpenBurnBar "))
            }
        case .codex, .forge, .grok:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false } // try?-ok(unreadable means not OpenBurnBar-owned)
            return text.contains(Self.sentinelStart)
        case .antigravity, .cursorAgent:
            return false
        }
    }

    /// Compares a routed client's on-disk OpenBurnBar model entries with the
    /// live route-eligible catalog. Droid caches concrete BYOK rows, Codex uses
    /// an OpenBurnBar-owned sidecar `model_catalog_json`, and Claude Code caches
    /// gateway discovery results, so all three need the same stale/current
    /// contract.
    func modelSyncStatus(
        target: RoutingClientWiringTarget,
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel]
    ) -> RoutingClientModelSyncStatus {
        switch target {
        case .droid:
            let expected = gatewayServedModelIDs(advertisedModels)
            let installed = installedDroidOpenBurnBarModelIDs(gateway: gateway)
            guard !installed.isEmpty else { return .notWired }
            guard Set(installed) == Set(expected) else {
                return .stale(installedModelIDs: installed, expectedModelIDs: expected)
            }
            // If the gateway auth token has rotated since the last wire, every
            // custom model entry still carries the old API key → 401 on every
            // Droid request. Treat a key mismatch as stale so the sentry
            // re-wires immediately with the current token.
            guard droidAPIKeyMatchesGateway(gateway: gateway) else {
                return .stale(installedModelIDs: installed, expectedModelIDs: expected)
            }
            return .current(modelIDs: installed)
        case .codex:
            let expected = gatewayServedModelIDs(advertisedModels, target: .codex)
            let installed = installedCodexOpenBurnBarModelIDs()
            guard isWired(target: target), !installed.isEmpty else { return .notWired }
            guard Set(installed) == Set(expected) else {
                return .stale(installedModelIDs: installed, expectedModelIDs: expected)
            }
            // Metadata-only catalog changes (context window, input
            // modalities) keep the model-ID sets identical, so compare the
            // capability-aware fingerprint too. A missing fingerprint means
            // a pre-metadata wiring and triggers one refreshing rewrite.
            let expectedFingerprint = codexModelCatalogFingerprint(
                advertisedModels: advertisedModels,
                gateway: gateway
            )
            guard installedCodexCatalogFingerprint() == expectedFingerprint else {
                return .stale(installedModelIDs: installed, expectedModelIDs: expected)
            }
            return .current(modelIDs: installed)
        case .claudeCode:
            let expected = gatewayServedModelIDs(advertisedModels, target: .claudeCode)
            let installed = installedClaudeOpenBurnBarModelIDs()
            guard isWired(target: target), !installed.isEmpty else { return .notWired }
            let expectedFingerprint = modelCatalogFingerprint(modelIDs: expected, gateway: gateway)
            guard installedClaudeCatalogFingerprint() == expectedFingerprint,
                  Set(installed) == Set(expected) else {
                return .stale(installedModelIDs: installed, expectedModelIDs: expected)
            }
            return .current(modelIDs: installed)
        case .opencode, .forge, .grok:
            return isWired(target: target) ? .current(modelIDs: []) : .notWired
        case .antigravity:
            return .notWired
        case .cursorAgent:
            return .notWired
        }
    }
}
