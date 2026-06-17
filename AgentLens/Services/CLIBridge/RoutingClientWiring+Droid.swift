import Foundation

extension RoutingClientWiring {

    // MARK: - Droid (~/.factory/{settings.local.json,settings.json,config.json})

    func wireDroid(
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel]
    ) throws -> RoutingClientWiringChange {
        let url = configURL(for: .droid)
        let liveModels = try gatewayServedModelsOrThrow(advertisedModels)
        let backupURL = try writeDroidSettingsStyleModels(
            to: url,
            gateway: gateway,
            liveModels: liveModels
        )
        try writeDroidSettingsStyleModels(
            to: home.appendingPathComponent(".factory/settings.json"),
            gateway: gateway,
            liveModels: liveModels
        )
        try writeDroidConfigStyleModels(
            to: home.appendingPathComponent(".factory/config.json"),
            gateway: gateway,
            liveModels: liveModels
        )
        return RoutingClientWiringChange(
            target: .droid,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    func unwireDroid() throws {
        var removedAny = false
        for url in droidConfigURLs() where fileManager.fileExists(atPath: url.path) {
            var (root, _) = try loadJSONObjectWithBackup(at: url)
            let removedSettings = removeOpenBurnBarDroidModels(
                key: "customModels",
                from: &root
            )
            let removedConfig = removeOpenBurnBarDroidModels(
                key: "custom_models",
                from: &root
            )
            let removedDefaults = removeManagedDroidDefaultModel(from: &root)
            guard removedSettings || removedConfig || removedDefaults else { continue }
            removedAny = true
            if root.isEmpty {
                try? fileManager.removeItem(at: url) // try?-ok(empty-file cleanup, cosmetic)
            } else {
                try writeJSONObject(root, to: url)
            }
        }
        guard removedAny else {
            throw RoutingClientWiringError.notEnabled
        }
    }

    @discardableResult
    func writeDroidSettingsStyleModels(
        to url: URL,
        gateway: RoutingClientGateway,
        liveModels: [RoutingClientAdvertisedModel]
    ) throws -> URL? {
        var (root, backupURL) = try loadJSONObjectWithBackup(at: url)
        var customModels = (root["customModels"] as? [[String: Any]]) ?? []
        customModels.removeAll { isOpenBurnBarDroidModel($0, gateway: gateway) }
        let startIndex = customModels.count
        let openBurnBarModels = liveModels.enumerated().map { offset, model in
            droidSettingsStyleModelEntry(
                model: model,
                gateway: gateway,
                index: startIndex + offset
            )
        }
        customModels.append(contentsOf: openBurnBarModels)
        root["customModels"] = customModels
        updateDroidDefaultModelIfManaged(
            root: &root,
            fallbackModelID: preferredDroidDefaultModelID(from: openBurnBarModels)
        )
        try writeJSONObject(root, to: url)
        return backupURL
    }

    func writeDroidConfigStyleModels(
        to url: URL,
        gateway: RoutingClientGateway,
        liveModels: [RoutingClientAdvertisedModel]
    ) throws {
        var (root, _) = try loadJSONObjectWithBackup(at: url)
        var customModels = (root["custom_models"] as? [[String: Any]]) ?? []
        customModels.removeAll { isOpenBurnBarDroidModel($0, gateway: gateway) }
        customModels.append(contentsOf: liveModels.map { model in
            [
                "model_display_name": droidDisplayName(for: model),
                "model": model.id,
                "base_url": model.droidBaseURL(gateway: gateway),
                "api_key": gateway.effectiveClientToken,
                "max_output_tokens": 8192,
                "provider": model.droidProviderType
            ] as [String: Any]
        })
        root["custom_models"] = customModels
        try writeJSONObject(root, to: url)
    }

    func droidSettingsStyleModelEntry(
        model: RoutingClientAdvertisedModel,
        gateway: RoutingClientGateway,
        index: Int
    ) -> [String: Any] {
        [
            "model": model.id,
            "id": droidCustomModelID(for: model, index: index),
            "index": index,
            "baseUrl": model.droidBaseURL(gateway: gateway),
            "apiKey": gateway.effectiveClientToken,
            "displayName": droidDisplayName(for: model),
            "maxOutputTokens": 8192,
            "provider": model.droidProviderType
        ]
    }

    func droidDisplayName(for model: RoutingClientAdvertisedModel) -> String {
        let trimmedDisplayName = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmedDisplayName.isEmpty ? model.id : trimmedDisplayName
        let sourceName = droidSourceDisplayName(for: model)
        if baseName.localizedCaseInsensitiveContains(sourceName) {
            return "OBB \(baseName)"
        }
        return "OBB \(baseName) \(sourceName)"
    }

    func droidSourceDisplayName(for model: RoutingClientAdvertisedModel) -> String {
        let providerID = model.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerName = model.providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceText = "\(providerID) \(providerName)".lowercased()

        if sourceText.contains("opencode") { return "OpenCode" }
        if sourceText.contains("ollama") { return "Ollama Cloud" }
        if sourceText.contains("factory") || sourceText.contains("droid") { return "Factory" }

        return "Direct"
    }

    func droidCustomModelID(
        for model: RoutingClientAdvertisedModel,
        index: Int
    ) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let sanitized = model.id
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        let slug = sanitized
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
            .isEmpty ? "model" : sanitized
        return "custom:OpenBurnBar-\(slug)-\(index)"
    }

    func preferredDroidDefaultModelID(from models: [[String: Any]]) -> String? {
        let nonAnthropic = models.first {
            (($0["provider"] as? String)?.lowercased() ?? "") != "anthropic"
        }
        return (nonAnthropic ?? models.first)?["id"] as? String
    }

    func removeOpenBurnBarDroidModels(
        key: String,
        from root: inout [String: Any]
    ) -> Bool {
        guard var customModels = root[key] as? [[String: Any]],
              customModels.contains(where: { isOpenBurnBarDroidModel($0) }) else {
            return false
        }
        customModels.removeAll { isOpenBurnBarDroidModel($0) }
        if customModels.isEmpty {
            root.removeValue(forKey: key)
        } else {
            root[key] = customModels
        }
        return true
    }

    func droidConfigURLs() -> [URL] {
        [
            configURL(for: .droid),
            home.appendingPathComponent(".factory/settings.json"),
            home.appendingPathComponent(".factory/config.json")
        ]
    }

    func isOpenBurnBarDroidModel(
        _ entry: [String: Any],
        gateway: RoutingClientGateway? = nil
    ) -> Bool {
        let provider = (entry["provider"] as? String)?.lowercased()
        let id = (entry["id"] as? String)?.lowercased()
        let displayName = (entry["displayName"] as? String)?.lowercased()
            ?? (entry["model_display_name"] as? String)?.lowercased()
        let model = (entry["model"] as? String)?.lowercased()
        let baseURL = (entry["baseUrl"] as? String) ?? (entry["base_url"] as? String)
        let isGatewayEntry = baseURL.map { isLocalGatewayURL($0) || matchesGatewayURL($0, gateway: gateway) } == true
        return provider == "openburnbar"
            || id?.hasPrefix("custom:openburnbar") == true
            || id?.hasPrefix("openburnbar:") == true
            || id?.contains("vibeproxy") == true
            || displayName?.hasPrefix("openburnbar ") == true
            || displayName?.hasPrefix("obb ") == true
            || displayName?.contains("vibeproxy") == true
            || model?.hasPrefix("openburnbar:") == true
            || ((provider == "openai"
                 || provider == "anthropic"
                 || provider == "generic-chat-completion-api")
                && isGatewayEntry)
    }

    func updateDroidDefaultModelIfManaged(
        root: inout [String: Any],
        fallbackModelID: String?
    ) {
        guard let fallbackModelID else { return }
        if shouldReplaceDroidDefaultModel(root["model"] as? String) {
            root["model"] = fallbackModelID
        }
        if shouldReplaceDroidDefaultModel(root["defaultModel"] as? String) {
            root["defaultModel"] = fallbackModelID
        }
        if var sessionDefaultSettings = root["sessionDefaultSettings"] as? [String: Any],
           shouldReplaceDroidDefaultModel(sessionDefaultSettings["model"] as? String) {
            sessionDefaultSettings["model"] = fallbackModelID
            root["sessionDefaultSettings"] = sessionDefaultSettings
        }
    }

    func shouldReplaceDroidDefaultModel(_ value: String?) -> Bool {
        guard let value else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return isManagedDroidDefaultModel(trimmed)
    }

    func isManagedDroidDefaultModel(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowercased = trimmed.lowercased()
        return lowercased.hasPrefix("custom:openburnbar")
            || lowercased.hasPrefix("openburnbar:")
            || lowercased.contains("vibeproxy")
    }

    @discardableResult
    func removeManagedDroidDefaultModel(from root: inout [String: Any]) -> Bool {
        var removed = false
        if isManagedDroidDefaultModel(root["model"] as? String) {
            root.removeValue(forKey: "model")
            removed = true
        }
        if isManagedDroidDefaultModel(root["defaultModel"] as? String) {
            root.removeValue(forKey: "defaultModel")
            removed = true
        }
        if var sessionDefaultSettings = root["sessionDefaultSettings"] as? [String: Any],
           isManagedDroidDefaultModel(sessionDefaultSettings["model"] as? String) {
            sessionDefaultSettings.removeValue(forKey: "model")
            if sessionDefaultSettings.isEmpty {
                root.removeValue(forKey: "sessionDefaultSettings")
            } else {
                root["sessionDefaultSettings"] = sessionDefaultSettings
            }
            removed = true
        }
        return removed
    }

    func isLocalGatewayURL(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost",
              components.port == 8317 else {
            return false
        }
        return true
    }

    func matchesGatewayURL(_ rawValue: String, gateway: RoutingClientGateway?) -> Bool {
        guard let gateway,
              let components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let gatewayComponents = URLComponents(string: gateway.baseURL),
              let host = components.host?.lowercased(),
              let gatewayHost = gatewayComponents.host?.lowercased(),
              host == gatewayHost,
              components.port == gatewayComponents.port else {
            return false
        }
        return true
    }

    func gatewayServedModelsOrThrow(
        _ advertisedModels: [RoutingClientAdvertisedModel]
    ) throws -> [RoutingClientAdvertisedModel] {
        let models = gatewayServedModels(advertisedModels, target: .droid)
        guard !models.isEmpty else {
            throw RoutingClientWiringError.gatewayMisconfigured(
                detail: "No route-eligible gateway models are advertised by /v1/models. Add or enable an account/provider before wiring this CLI."
            )
        }
        return models
    }

    func gatewayServedModels(
        _ advertisedModels: [RoutingClientAdvertisedModel],
        target: RoutingClientWiringTarget
    ) -> [RoutingClientAdvertisedModel] {
        Self.logicalProviderModelCatalog(advertisedModels)
            .filter { $0.isGatewayServedModelCandidate(for: target) }
    }

    func gatewayServedModelIDs(
        _ advertisedModels: [RoutingClientAdvertisedModel],
        target: RoutingClientWiringTarget = .droid
    ) -> [String] {
        gatewayServedModels(advertisedModels, target: target)
            .map(\.id)
            .uniquedPreservingOrder()
    }

    func firstGatewayServedModel(
        _ advertisedModels: [RoutingClientAdvertisedModel],
        target: RoutingClientWiringTarget
    ) -> RoutingClientAdvertisedModel? {
        gatewayServedModels(advertisedModels, target: target).first
    }

    func installedDroidOpenBurnBarModelIDs(
        gateway: RoutingClientGateway
    ) -> [String] {
        var installed: [String] = []
        for url in droidConfigURLs() where fileManager.fileExists(atPath: url.path) {
            guard let root = try? readJSONObject(at: url) else { continue } // try?-ok(skip unparseable config)
            let settingsModels = (root["customModels"] as? [[String: Any]]) ?? []
            let configModels = (root["custom_models"] as? [[String: Any]]) ?? []
            for entry in settingsModels + configModels where isOpenBurnBarDroidModel(entry, gateway: gateway) {
                guard let model = entry["model"] as? String,
                      !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                installed.append(model)
            }
        }
        return installed.uniquedPreservingOrder()
    }

    /// Returns `true` when every OpenBurnBar model entry in all Droid config
    /// files carries the current gateway token as its `apiKey` / `api_key`.
    /// Returns `true` vacuously when no OBB entries are found (the model-ID
    /// check handles the not-wired case separately).
    func droidAPIKeyMatchesGateway(gateway: RoutingClientGateway) -> Bool {
        let expectedKey = gateway.effectiveClientToken
        for url in droidConfigURLs() where fileManager.fileExists(atPath: url.path) {
            let root: [String: Any]
            do {
                root = try readJSONObject(at: url)
            } catch {
                continue
            }
            let settingsModels = (root["customModels"] as? [[String: Any]]) ?? []
            let configModels = (root["custom_models"] as? [[String: Any]]) ?? []
            for entry in settingsModels + configModels where isOpenBurnBarDroidModel(entry, gateway: gateway) {
                let storedKey = (entry["apiKey"] as? String)
                    ?? (entry["api_key"] as? String)
                    ?? ""
                if storedKey.trimmingCharacters(in: .whitespacesAndNewlines) != expectedKey {
                    return false
                }
            }
        }
        return true
    }
}
