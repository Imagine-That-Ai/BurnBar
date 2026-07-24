import Foundation
import OpenBurnBarCore

extension RoutingClientWiring {

    // MARK: - Claude Code (~/.claude/settings.json)

    func wireClaudeCode(
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel],
        migrateExistingVibeProxy: Bool = false
    ) throws -> RoutingClientWiringChange {
        let url = configURL(for: .claudeCode)
        var (root, backupURL) = try loadJSONObjectWithBackup(at: url)

        var env = (root["env"] as? [String: Any]) ?? [:]
        if migrateExistingVibeProxy {
            removeVibeProxyEnvironmentKeys(from: &env)
        }
        env["ANTHROPIC_BASE_URL"] = gateway.baseURL
        env["ANTHROPIC_AUTH_TOKEN"] = gateway.effectiveClientToken
        env[Self.claudeDiscoveryFlagKey] = "1"
        env["ANTHROPIC_CUSTOM_HEADERS"] = Self.mergedClaudeCustomHeaders(
            existing: env["ANTHROPIC_CUSTOM_HEADERS"] as? String
        )
        let modelIDs = gatewayServedModelIDs(advertisedModels, target: .claudeCode)
        env[Self.claudeCatalogFingerprintKey] = modelCatalogFingerprint(
            modelIDs: modelIDs,
            gateway: gateway
        )
        env[Self.claudeCatalogIDsKey] = modelIDs.joined(separator: ",")
        // Used by `isWired(...)` for round-trip detection. Never read by
        // Claude Code itself.
        env["OPENBURNBAR_WIRED"] = "1"
        root["env"] = env

        try writeJSONObject(root, to: url)
        return RoutingClientWiringChange(
            target: .claudeCode,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    func unwireClaudeCode() throws {
        let url = configURL(for: .claudeCode)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RoutingClientWiringError.notEnabled
        }
        var (root, _) = try loadJSONObjectWithBackup(at: url)
        guard var env = root["env"] as? [String: Any] else {
            throw RoutingClientWiringError.notEnabled
        }
        env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        env.removeValue(forKey: Self.claudeDiscoveryFlagKey)
        env.removeValue(forKey: Self.claudeCatalogFingerprintKey)
        env.removeValue(forKey: Self.claudeCatalogIDsKey)
        if let headers = Self.removingOpenBurnBarClaudeHeaders(from: env["ANTHROPIC_CUSTOM_HEADERS"] as? String) {
            env["ANTHROPIC_CUSTOM_HEADERS"] = headers
        } else {
            env.removeValue(forKey: "ANTHROPIC_CUSTOM_HEADERS")
        }
        env.removeValue(forKey: "OPENBURNBAR_WIRED")
        if env.isEmpty {
            root.removeValue(forKey: "env")
        } else {
            root["env"] = env
        }
        try writeJSONObject(root, to: url)
    }

    // MARK: - Codex (~/.codex/config.toml)

    func wireCodex(
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel],
        migrateExistingVibeProxy: Bool = false
    ) throws -> RoutingClientWiringChange {
        let url = configURL(for: .codex)
        let existing = readText(at: url) ?? ""
        var stripped = stripSentinelBlock(in: existing)
        stripped = stripOpenBurnBarLegacyCodexSections(in: stripped)
        if migrateExistingVibeProxy {
            stripped = stripVibeProxyTOMLSections(
                in: stripped,
                sectionPrefixes: ["model_providers.", "profiles."]
            )
        }
        let block = codexTOMLBlock(gateway: gateway, advertisedModels: advertisedModels)
        let separator = stripped.isEmpty || stripped.hasSuffix("\n") ? "" : "\n"
        let next = stripped + separator + block + "\n"

        let backupURL = try backupIfExists(url: url)
        try writeText(next, to: url)
        try writeCodexProfile(gateway: gateway, advertisedModels: advertisedModels)
        try writeCodexModelCatalog(advertisedModels: advertisedModels)
        return RoutingClientWiringChange(
            target: .codex,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    func unwireCodex() throws {
        let url = configURL(for: .codex)
        guard let existing = readText(at: url) else {
            throw RoutingClientWiringError.notEnabled
        }
        guard existing.contains(Self.sentinelStart) else {
            throw RoutingClientWiringError.notEnabled
        }
        let next = stripSentinelBlock(in: existing)
        if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fileManager.removeItem(at: url) // try?-ok(empty-file cleanup, cosmetic)
        } else {
            _ = try? backupIfExists(url: url) // try?-ok(best-effort sidecar backup)
            try writeText(next, to: url)
        }
        try removeOpenBurnBarCodexSidecars()
    }

    // MARK: - Grok Build (~/.grok/config.toml)

    func wireGrok(
        gateway: RoutingClientGateway,
        migrateExistingVibeProxy: Bool = false
    ) throws -> RoutingClientWiringChange {
        let url = configURL(for: .grok)
        let existing = readText(at: url) ?? ""
        var stripped = stripSentinelBlock(in: existing)
        if migrateExistingVibeProxy {
            stripped = stripVibeProxyTOMLSections(in: stripped, sectionPrefixes: ["model."])
        }
        let block = grokTOMLBlock(gateway: gateway)
        let separator = stripped.isEmpty || stripped.hasSuffix("\n") ? "" : "\n"
        let next = stripped + separator + block + "\n"

        let backupURL = try backupIfExists(url: url)
        try writeText(next, to: url)
        return RoutingClientWiringChange(
            target: .grok,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    func unwireGrok() throws {
        let url = configURL(for: .grok)
        guard let existing = readText(at: url) else {
            throw RoutingClientWiringError.notEnabled
        }
        guard existing.contains(Self.sentinelStart) else {
            throw RoutingClientWiringError.notEnabled
        }
        let next = stripSentinelBlock(in: existing)
        if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fileManager.removeItem(at: url) // try?-ok(empty-file cleanup, cosmetic)
        } else {
            _ = try? backupIfExists(url: url) // try?-ok(best-effort sidecar backup)
            try writeText(next, to: url)
        }
    }

    private func grokTOMLBlock(gateway: RoutingClientGateway) -> String {
        """
        \(Self.sentinelStart)
        # Managed by OpenBurnBar. Edit Settings -> Agents -> CLIs to change.
        # Select the `openburnbar` custom model in Grok Build, or set
        # [models] default = "openburnbar" when you want it session-wide.
        [model.openburnbar]
        model = "openburnbar-gateway"
        base_url = "\(gateway.baseURL)/v1"
        name = "OpenBurnBar Gateway"
        env_key = "XAI_API_KEY"
        \(Self.sentinelEnd)
        """
    }

    private func codexTOMLBlock(
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel]
    ) -> String {
        // The provider block defines *how* to talk to the gateway; the
        // profile makes one-line activation possible:
        //
        //     codex --profile openburnbar
        //
        // The user still needs to export OPENBURNBAR_GATEWAY_TOKEN so Codex
        // can read the bearer at runtime. The Settings -> Agents -> CLIs row
        // shows the exact export command and the shell-snippet sheet
        // includes it verbatim.
        return """
        \(Self.sentinelStart)
        # Managed by OpenBurnBar. Edit Settings -> Agents -> CLIs to change.
        # To activate this provider:
        #   1. export OPENBURNBAR_GATEWAY_TOKEN='<your gateway token>'
        #   2. codex --profile openburnbar
        # Or set OPENAI_BASE_URL/OPENAI_API_KEY directly and skip the profile.
        [model_providers.openburnbar]
        name = "OpenBurnBar Gateway"
        base_url = "\(gateway.baseURL)/v1"
        env_key = "OPENBURNBAR_GATEWAY_TOKEN"
        wire_api = "responses"
        \(Self.sentinelEnd)
        """
    }

    private func codexProfileURL() -> URL {
        home.appendingPathComponent(".codex/\(Self.codexProfileName).config.toml")
    }

    func codexModelCatalogURL() -> URL {
        home.appendingPathComponent(".codex/\(Self.codexCatalogFileName)")
    }

    private func writeCodexProfile(
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel]
    ) throws {
        let url = codexProfileURL()
        let model = firstGatewayServedModel(advertisedModels, target: .codex)
            .map { codexProxyModelID(for: $0) }
            ?? "openburnbar/gateway-default"
        let catalogURL = codexModelCatalogURL().path
        let fingerprint = modelCatalogFingerprint(
            modelIDs: gatewayServedModelIDs(advertisedModels, target: .codex).map { "openburnbar/\($0)" },
            gateway: gateway
        )
        let text = """
        \(Self.sentinelStart)
        # Managed by OpenBurnBar. Edit Settings -> Agents -> CLIs to change.
        model_provider = "openburnbar"
        model = "\(Self.tomlString(model))"
        model_catalog_json = "\(Self.tomlString(catalogURL))"
        openburnbar_model_catalog_fingerprint = "\(fingerprint)"
        \(Self.sentinelEnd)
        """
        _ = try? backupIfExists(url: url) // try?-ok(best-effort sidecar backup)
        try writeText(text + "\n", to: url)
    }

    private func writeCodexModelCatalog(
        advertisedModels: [RoutingClientAdvertisedModel]
    ) throws {
        let url = codexModelCatalogURL()
        let proxyRows = gatewayServedModels(advertisedModels, target: .codex).map { model in
            codexModelCatalogRow(
                slug: codexProxyModelID(for: model),
                displayName: model.displayName.isEmpty ? model.id : model.displayName,
                providerName: "\(model.providerName) via OpenBurnBar",
                priority: 10_000,
                contextWindow: model.contextWindowTokens ?? 65_536,
                inputModalities: model.inputModalities
            )
        }
        let rows = Self.codexNativeFallbackCatalogRows + proxyRows
        let object = ["models": rows]
        guard JSONSerialization.isValidJSONObject(object) else {
            throw RoutingClientWiringError.configWriteFailed(
                path: url.path,
                detail: "could not encode Codex model catalog"
            )
        }
        do {
            try ensureParentDirectory(of: url)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: [.atomic])
        } catch {
            throw RoutingClientWiringError.configWriteFailed(path: url.path, detail: error.localizedDescription)
        }
    }

    private func removeOpenBurnBarCodexSidecars() throws {
        for url in [codexProfileURL(), codexModelCatalogURL()] where fileManager.fileExists(atPath: url.path) {
            if url.pathExtension == "toml",
               let text = readText(at: url),
               !text.contains(Self.sentinelStart) {
                continue
            }
            try? fileManager.removeItem(at: url) // try?-ok(best-effort sidecar cleanup)
        }
    }

    func codexProxyModelID(for model: RoutingClientAdvertisedModel) -> String {
        "openburnbar/\(model.id)"
    }

    private func codexModelCatalogRow(
        slug: String,
        displayName: String,
        providerName: String,
        priority: Int,
        contextWindow: Int,
        inputModalities: [String]
    ) -> [String: Any] {
        let effectiveContextWindow = max(1, contextWindow)
        return [
            "slug": slug,
            "display_name": OpenBurnBarModelDisplayName.compose(
                modelName: displayName,
                providerName: providerName,
                providerID: "openburnbar"
            ),
            "description": providerName,
            "default_reasoning_level": NSNull(),
            "supported_reasoning_levels": [],
            "shell_type": "shell_command",
            "visibility": "list",
            "supported_in_api": true,
            "priority": priority,
            "additional_speed_tiers": [],
            "service_tiers": [],
            "availability_nux": NSNull(),
            "upgrade": NSNull(),
            "base_instructions": "You are Codex, a coding agent.",
            "model_messages": NSNull(),
            "supports_reasoning_summaries": false,
            "default_reasoning_summary": "auto",
            "support_verbosity": false,
            "default_verbosity": NSNull(),
            "apply_patch_tool_type": NSNull(),
            "web_search_tool_type": "text",
            "truncation_policy": ["mode": "tokens", "limit": effectiveContextWindow],
            "supports_parallel_tool_calls": false,
            "supports_image_detail_original": false,
            "context_window": effectiveContextWindow,
            "max_context_window": effectiveContextWindow,
            "auto_compact_token_limit": NSNull(),
            "effective_context_window_percent": 95,
            "experimental_supported_tools": [],
            "input_modalities": inputModalities.isEmpty ? ["text"] : inputModalities,
            "supports_search_tool": false
        ]
    }

    private static var codexNativeFallbackCatalogRows: [[String: Any]] {
        [
            codexNativeFallbackCatalogRow(slug: "gpt-5.5", displayName: "GPT-5.5", priority: 100),
            codexNativeFallbackCatalogRow(slug: "gpt-5.5-codex", displayName: "GPT-5.5 Codex", priority: 90),
            codexNativeFallbackCatalogRow(slug: "gpt-5.4", displayName: "GPT-5.4", priority: 80)
        ]
    }

    private static func codexNativeFallbackCatalogRow(
        slug: String,
        displayName: String,
        priority: Int
    ) -> [String: Any] {
        [
            "slug": slug,
            "display_name": OpenBurnBarModelDisplayName.compose(
                modelName: displayName,
                providerName: "OpenAI",
                providerID: "openai",
                reasoningLevel: "CLI default"
            ),
            "description": "OpenAI via Codex CLI",
            "default_reasoning_level": NSNull(),
            "supported_reasoning_levels": [],
            "shell_type": "shell_command",
            "visibility": "list",
            "supported_in_api": true,
            "priority": priority,
            "additional_speed_tiers": [],
            "service_tiers": [],
            "availability_nux": NSNull(),
            "upgrade": NSNull(),
            "base_instructions": "You are Codex, a coding agent.",
            "model_messages": NSNull(),
            "supports_reasoning_summaries": false,
            "default_reasoning_summary": "auto",
            "support_verbosity": false,
            "default_verbosity": NSNull(),
            "apply_patch_tool_type": NSNull(),
            "web_search_tool_type": "text",
            "truncation_policy": ["mode": "tokens", "limit": 65_536],
            "supports_parallel_tool_calls": false,
            "supports_image_detail_original": false,
            "context_window": 65_536,
            "max_context_window": 65_536,
            "auto_compact_token_limit": NSNull(),
            "effective_context_window_percent": 95,
            "experimental_supported_tools": [],
            "input_modalities": ["text"],
            "supports_search_tool": false
        ]
    }
}
