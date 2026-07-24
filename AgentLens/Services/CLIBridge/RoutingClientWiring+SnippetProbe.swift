import Foundation

extension RoutingClientWiring {

    // MARK: - Snippet-mode wiring

    enum AdvertisedModelsResult: Sendable {
        case unavailable
        case available([RoutingClientAdvertisedModel])
    }

    /// A copy/pasteable shell block that achieves the same wiring without
    /// touching any config file. Users on managed dotfiles or non-standard
    /// shells prefer this path. The snippet is always self-contained and can
    /// be pasted into `~/.zshrc`, `~/.bashrc`, or sourced ad-hoc.
    ///
    /// Tokens are emitted inside single quotes so `$`, backticks, double
    /// quotes, and backslashes pass through verbatim. Any literal `'` in
    /// the token is escaped with the standard `'\''` POSIX dance.
    func shellSnippet(
        target: RoutingClientWiringTarget,
        gateway: RoutingClientGateway
    ) -> String {
        let baseURL = Self.shellQuote(gateway.baseURL)
        let openAIBaseURL = Self.shellQuote("\(gateway.baseURL)/v1")
        let token = Self.shellQuote(gateway.effectiveClientToken)
        switch target {
        case .claudeCode:
            return """
            # OpenBurnBar — wire Claude Code through the local gateway
            export ANTHROPIC_BASE_URL=\(baseURL)
            export ANTHROPIC_AUTH_TOKEN=\(token)
            export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
            export ANTHROPIC_CUSTOM_HEADERS=\(Self.shellQuote(Self.claudeCodeClientHeader))
            """
        case .codex:
            return """
            # OpenBurnBar — wire Codex CLI through the local gateway
            # OpenBurnBar Settings -> Agents -> CLIs writes
            # ~/.codex/openburnbar.config.toml and a merged model catalog so:
            #   codex exec --profile openburnbar --model openburnbar/<model> "..."
            # works with the local gateway.
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            """
        case .opencode:
            return """
            # OpenBurnBar — wire OpenCode CLI through the local gateway
            # The Settings -> Agents -> CLIs Connect button adds provider.openburnbar to
            # ~/.config/opencode/opencode.json.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
        case .forge:
            return """
            # OpenBurnBar — wire Forge CLI through the local gateway
            # The Settings -> Agents -> CLIs Connect button adds a Forge provider named `openburnbar`
            # at ~/forge/.forge.toml. This env var supplies its api_key_var.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
        case .droid:
            return """
            # OpenBurnBar — wire Droid CLI through the local gateway
            # In OpenBurnBar Settings -> Agents -> CLIs, press Connect + Sync
            # or Sync models to write live BurnBar models under ~/.factory/.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
        case .grok:
            return """
            # OpenBurnBar — wire Grok Build CLI through the local gateway
            # Settings -> Agents -> CLIs writes [model.openburnbar] into ~/.grok/config.toml.
            export XAI_API_KEY=\(token)
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            """
        case .antigravity:
            return """
            # OpenBurnBar — Antigravity currently uses profile-scoped config
            # directories rather than a file-based OpenAI-compatible gateway
            # setting that BurnBar can safely rewrite. Use OpenBurnBar's
            # Antigravity profile launcher for account-scoped sessions.
            export AGY_CONFIG_HOME=$HOME/.gemini/antigravity-cli
            export ANTIGRAVITY_HOME=$HOME/.gemini/antigravity-cli
            """
        case .cursorAgent:
            return """
            # OpenBurnBar — Cursor Agent currently uses profile-scoped config
            # directories rather than a file-based OpenAI-compatible gateway
            # setting that BurnBar can safely rewrite. Use OpenBurnBar's
            # Cursor Agent profile launcher for account-scoped sessions.
            export CURSOR_AGENT_HOME=$HOME/.cursor-agent
            export CURSOR_AGENT_CONFIG_PATH=$HOME/.cursor-agent
            """
        }
    }

    func advertisedModels(
        gateway: RoutingClientGateway,
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = 8
    ) async -> [RoutingClientAdvertisedModel] {
        switch await advertisedModelsWithAvailability(
            gateway: gateway,
            session: session,
            timeoutSeconds: timeoutSeconds
        ) {
        case .unavailable:
            return []
        case .available(let models):
            return models
        }
    }

    /// Returns whether the gateway answered successfully separately from the
    /// catalog contents. A successful empty catalog is authoritative and must
    /// remove stale proxy choices; an unavailable gateway should use fallback
    /// data when one exists.
    func advertisedModelsWithAvailability(
        gateway: RoutingClientGateway,
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = 8
    ) async -> AdvertisedModelsResult {
        guard let url = URL(string: gateway.baseURL)?.appending(path: "v1/models") else {
            return .unavailable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        if !gateway.authToken.isEmpty {
            request.setValue("Bearer \(gateway.authToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["data"] as? [[String: Any]] else {
                return .unavailable
            }
            let models: [RoutingClientAdvertisedModel] = rows.compactMap { row -> RoutingClientAdvertisedModel? in
                guard let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty else {
                    return nil
                }
                let providerID = (row["provider_id"] as? String)
                    ?? (row["owned_by"] as? String)
                    ?? "openburnbar"
                let providerName = (row["provider_name"] as? String)
                    ?? providerID
                return RoutingClientAdvertisedModel(
                    id: id,
                    displayName: (row["display_name"] as? String) ?? id,
                    providerID: providerID,
                    providerName: providerName,
                    formatFamily: (row["format_family"] as? String) ?? "openai_compat",
                    servedEndpoints: (row["served_endpoints"] as? [String]) ?? [],
                    capabilities: (row["capabilities"] as? [String]) ?? [],
                    routeEligible: (row["route_eligible"] as? Bool) ?? true
                )
            }
            return .available(Self.logicalProviderModelCatalog(models))
        } catch {
            AppLogger.network.error("routing_client_probe_models_failed", metadata: ["error": error.localizedDescription])
            return .unavailable
        }
    }

    static func logicalProviderModelCatalog(
        _ models: [RoutingClientAdvertisedModel]
    ) -> [RoutingClientAdvertisedModel] {
        let normalizedRows = models.map { model in
            normalizedLegacyAccountScopedModel(model)
        }
        let duplicateRawIDs = Set(
            Dictionary(grouping: normalizedRows) {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            .compactMap { entry -> String? in
                let id = entry.key
                let providerIDs = Set(entry.value.map { $0.providerID.lowercased() })
                return id.isEmpty || providerIDs.count < 2 ? nil : id
            }
        )

        var seen: Set<String> = []
        var logicalRows: [RoutingClientAdvertisedModel] = []
        for row in normalizedRows {
            let rawID = row.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawID.isEmpty else { continue }
            let routedID = duplicateRawIDs.contains(rawID.lowercased())
                ? "\(row.providerID)/\(rawID)"
                : rawID
            let key = "\(row.providerID.lowercased())|\(routedID.lowercased())"
            guard seen.insert(key).inserted else { continue }
            logicalRows.append(
                RoutingClientAdvertisedModel(
                    id: routedID,
                    displayName: row.displayName,
                    providerID: row.providerID,
                    providerName: row.providerName,
                    formatFamily: row.formatFamily,
                    servedEndpoints: row.servedEndpoints,
                    capabilities: row.capabilities,
                    routeEligible: row.routeEligible
                )
            )
        }
        return logicalRows
    }

    private static func normalizedLegacyAccountScopedModel(
        _ model: RoutingClientAdvertisedModel
    ) -> RoutingClientAdvertisedModel {
        let parts = model.id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3,
              parts[0].caseInsensitiveCompare(model.providerID) == .orderedSame else {
            return model
        }
        let rawModelID = parts.dropFirst(2).joined(separator: "/")
        guard !rawModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return model
        }
        return RoutingClientAdvertisedModel(
            id: rawModelID,
            displayName: model.displayName,
            providerID: model.providerID,
            providerName: model.providerName,
            formatFamily: model.formatFamily,
            servedEndpoints: model.servedEndpoints,
            capabilities: model.capabilities,
            routeEligible: model.routeEligible
        )
    }

    /// POSIX-safe single-quoted shell argument. Embedded single quotes are
    /// emitted as the standard `'\''` sequence.
    static func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Probe

    /// Hit the local gateway with a `max_tokens: 1` request shaped for the
    /// target's wire format. Confirms the gateway responds before the helper
    /// reports "wired". Surfaces the upstream status code so failures point
    /// the user at the right account-management UI.
    func probe(
        target: RoutingClientWiringTarget,
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel] = [],
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = 8
    ) async -> RoutingClientWiringProbe {
        guard let url = probeURL(target: target, gateway: gateway) else {
            return .skipped(reason: "Could not construct probe URL for \(gateway.baseURL).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds
        if !gateway.authToken.isEmpty {
            request.setValue("Bearer \(gateway.authToken)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any]
        let probeModel: String
        switch target {
        case .antigravity:
            return .skipped(reason: "Antigravity is launched through profile switching, not routed client wiring.")
        case .cursorAgent:
            return .skipped(reason: "Cursor Agent is launched through profile switching, not routed client wiring.")
        case .claudeCode:
            let models = advertisedModels.isEmpty
                ? await self.advertisedModels(gateway: gateway, session: session, timeoutSeconds: timeoutSeconds)
                : advertisedModels
            guard let liveModel = firstGatewayServedModel(models, target: .claudeCode) else {
                return .failed(
                    status: 503,
                    message: "No route-eligible gateway models are advertised for /v1/messages."
                )
            }
            probeModel = liveModel.id
            // Anthropic Messages uses `max_tokens`. Older versions of the
            // Messages API rejected requests that didn't include this field,
            // so we send it explicitly even for a 1-token probe.
            body = [
                "model": probeModel,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]]
            ]
        case .codex:
            let models = advertisedModels.isEmpty
                ? await self.advertisedModels(gateway: gateway, session: session, timeoutSeconds: timeoutSeconds)
                : advertisedModels
            guard let liveModel = firstGatewayServedModel(models, target: .codex) else {
                return .failed(
                    status: 503,
                    message: "No route-eligible gateway models are advertised for /v1/responses."
                )
            }
            probeModel = codexProxyModelID(for: liveModel)
            body = [
                "model": probeModel,
                "input": "ping",
                "max_output_tokens": 1
            ]
        case .opencode, .forge, .droid, .grok:
            let models = advertisedModels.isEmpty
                ? await self.advertisedModels(gateway: gateway, session: session, timeoutSeconds: timeoutSeconds)
                : advertisedModels
            guard let liveModel = firstGatewayServedModel(models, target: target) else {
                return .failed(
                    status: 503,
                    message: "No route-eligible gateway models are advertised by /v1/models."
                )
            }
            probeModel = liveModel.id
            // OpenAI Chat Completions deprecated `max_tokens` for reasoning-
            // capable models in favor of `max_completion_tokens`. The
            // gateway's structured-executor tests use `max_completion_tokens`
            // (OpenBurnBarHTTPGatewayServerTests.swift:258), so we match.
            body = [
                "model": probeModel,
                "max_completion_tokens": 1,
                "messages": [["role": "user", "content": "ping"]]
            ]
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            return .failed(status: 0, message: "could not encode probe body: \(error.localizedDescription)")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(status: 0, message: "missing HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return .ok(modelID: probeModel)
            }
            let bodyText = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            return .failed(status: http.statusCode, message: String(bodyText))
        } catch {
            return .failed(status: 0, message: error.localizedDescription)
        }
    }

    // MARK: - Private helpers

    func assertGatewayConfigured(_ gateway: RoutingClientGateway) throws {
        if gateway.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RoutingClientWiringError.gatewayMisconfigured(detail: "Gateway host is empty.")
        }
        if gateway.port <= 0 || gateway.port > 65_535 {
            throw RoutingClientWiringError.gatewayMisconfigured(detail: "Gateway port \(gateway.port) is out of range.")
        }
        if gateway.authToken.isEmpty && !gateway.isLoopbackHost {
            throw RoutingClientWiringError.gatewayMisconfigured(
                detail: "A non-loopback gateway needs an auth token. Generate one under Settings → Daemon → HTTP gateway before wiring a client."
            )
        }
    }

    private func probeURL(target: RoutingClientWiringTarget, gateway: RoutingClientGateway) -> URL? {
        let base = URL(string: gateway.baseURL)
        switch target {
        case .antigravity:
            return nil
        case .cursorAgent:
            return nil
        case .claudeCode:
            return base?.appending(path: "v1/messages")
        case .codex:
            return base?.appending(path: "v1/responses")
        case .opencode, .forge, .droid, .grok:
            return base?.appending(path: "v1/chat/completions")
        }
    }
}
