import Foundation

extension RoutingClientWiring {

    // MARK: - OpenCode (~/.config/opencode/opencode.json)

    func wireOpenCode(
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel],
        migrateExistingVibeProxy: Bool = false
    ) throws -> RoutingClientWiringChange {
        let url = configURL(for: .opencode)
        var (root, backupURL) = try loadJSONObjectWithBackup(at: url)
        var providers = (root["provider"] as? [String: Any]) ?? [:]
        if migrateExistingVibeProxy {
            removeVibeProxyOpenCodeProviders(from: &providers)
        }
        let liveModels = try gatewayServedModelsOrThrow(advertisedModels)
        providers["openburnbar"] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": "OpenBurnBar Gateway",
            "options": [
                "baseURL": "\(gateway.baseURL)/v1",
                "apiKey": gateway.effectiveClientToken
            ],
            "models": Dictionary(
                uniqueKeysWithValues: liveModels.map { model in
                    (model.id, ["name": model.displayName.isEmpty ? model.id : model.displayName])
                }
            )
        ]
        root["model"] = "openburnbar/\(liveModels[0].id)"
        root["provider"] = providers
        try writeJSONObject(root, to: url)
        return RoutingClientWiringChange(
            target: .opencode,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    func unwireOpenCode() throws {
        let url = configURL(for: .opencode)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RoutingClientWiringError.notEnabled
        }
        var (root, _) = try loadJSONObjectWithBackup(at: url)
        guard var providers = root["provider"] as? [String: Any],
              providers["openburnbar"] != nil else {
            throw RoutingClientWiringError.notEnabled
        }
        providers.removeValue(forKey: "openburnbar")
        if providers.isEmpty {
            root.removeValue(forKey: "provider")
        } else {
            root["provider"] = providers
        }
        try writeJSONObject(root, to: url)
    }

    // MARK: - Forge (~/forge/.forge.toml)

    func wireForge(
        gateway: RoutingClientGateway,
        migrateExistingVibeProxy: Bool = false
    ) throws -> RoutingClientWiringChange {
        let url = configURL(for: .forge)
        let existing = readText(at: url) ?? ""
        var stripped = stripSentinelBlock(in: existing)
        if migrateExistingVibeProxy {
            stripped = stripVibeProxyArrayTOMLBlocks(in: stripped, arrayHeader: "[[providers]]")
            stripped = replaceVibeProxyForgeSessionProvider(in: stripped)
        }
        let block = forgeTOMLBlock(gateway: gateway)
        let separator = stripped.isEmpty || stripped.hasSuffix("\n") ? "" : "\n"
        let next = stripped + separator + block + "\n"

        let backupURL = try backupIfExists(url: url)
        try writeText(next, to: url)
        return RoutingClientWiringChange(
            target: .forge,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    func unwireForge() throws {
        let url = configURL(for: .forge)
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

    private func forgeTOMLBlock(gateway: RoutingClientGateway) -> String {
        // Forge supports a chat-completions URL plus a separate models URL.
        // We do not change the active `[session]` provider so users can opt
        // in deliberately.
        """
        \(Self.sentinelStart)
        # Managed by OpenBurnBar. Edit Settings -> Agents -> CLIs to change.
        # To activate in Forge, select provider `openburnbar` or set it in
        # your Forge session after exporting OPENBURNBAR_GATEWAY_TOKEN.
        [[providers]]
        id = "openburnbar"
        api_key_var = "OPENBURNBAR_GATEWAY_TOKEN"
        url = "\(gateway.baseURL)/v1/chat/completions"
        models = "\(gateway.baseURL)/v1/models"
        response_type = "OpenAI"
        \(Self.sentinelEnd)
        """
    }
}
