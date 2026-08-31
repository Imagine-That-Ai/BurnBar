import OpenBurnBarEngine
import CryptoKit
import Foundation
import Network

// Model catalog & advertisement: /v1/models response shaping, suppression, grouping, matching, and route-key resolution.
// Extracted from OpenBurnBarHTTPGatewayServer.swift (god-file decomposition);
// an extension on the same actor — behavior- and isolation-identical.

extension BurnBarHTTPGatewayServer {

    func handleModels(
        includeUnadvertised: Bool = false,
        headers: [String: String] = [:]
    ) async -> GatewayHTTPResponse {
        do {
            let client = modelCatalogClient(from: headers)
            let catalog = configStore.catalogSupport.catalog
            let configSnapshot = try await configStore.snapshot()
            let suppressedBaseIDs = includeUnadvertised
                ? Set<String>()
                : suppressedBaseModelIDs(from: configSnapshot)
            let snapshot = try await catalogSource.snapshot()
            var entries: [GatewayModelCatalogEntry] = []
            for model in snapshot.models {
                if !includeUnadvertised,
                   isSuppressedBaseModelRow(model, suppressedBaseIDs: suppressedBaseIDs) {
                    continue
                }
                let canAdvertise = await catalogSource.canAdvertise(model, catalog: catalog)
                let advertised = model.routeEligible && model.advertisementEnabled && canAdvertise
                if advertised || (includeUnadvertised && model.enabled) {
                    entries.append(GatewayModelCatalogEntry(model: model, advertised: advertised))
                }
            }
            let groups = groupedModelCatalogEntries(entries)
            let duplicateModelIDs = duplicateAdvertisedModelIDs(in: groups)
            let models = groups.map { group in
                let routeID = gatewayRouteModelID(for: group, duplicateModelIDs: duplicateModelIDs)
                return ModelDescriptor(
                    group: group,
                    advertisedID: advertisedModelID(
                        routeID,
                        group: group,
                        for: client,
                        includeUnadvertised: includeUnadvertised
                    )
                )
            }
            return jsonResponse(status: 200, body: encodeBody(ModelsResponse(data: models)))
        } catch {
            logger.error("gateway_models_error", metadata: ["error": "\(error)"])
            return jsonResponse(status: 500, body: errorBody("internal error"))
        }
    }

    func resolveProxyModelOverride(
        forRequestedModel requestedModel: GatewayRequestedModel
    ) async -> GatewayProxyModelOverride? {
        guard let snapshot = try? await configStore.snapshot() else { return nil }
        let requested = requestedModel.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return nil }

        let providersToScan: [BurnBarProviderSettings]
        if let providerID = requestedModel.providerID {
            providersToScan = snapshot.providers.filter {
                $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame
            }
        } else {
            providersToScan = snapshot.providers
        }

        for provider in providersToScan {
            if let variant = provider.modelVariants.first(where: {
                $0.variantID.caseInsensitiveCompare(requested) == .orderedSame
            }) {
                let rewritten = GatewayRequestedModel(
                    originalID: requestedModel.originalID,
                    modelID: variant.baseModelID,
                    providerID: requestedModel.providerID ?? provider.providerID,
                    accountID: requestedModel.accountID
                )
                return GatewayProxyModelOverride(
                    requestedModel: rewritten,
                    advertisedRequestedModel: requestedModel,
                    variant: variant,
                    alias: nil
                )
            }
        }

        for provider in providersToScan {
            if let alias = provider.modelAliases.first(where: {
                $0.aliasID.caseInsensitiveCompare(requested) == .orderedSame
            }) {
                let rewritten = GatewayRequestedModel(
                    originalID: requestedModel.originalID,
                    modelID: alias.baseModelID,
                    providerID: requestedModel.providerID ?? provider.providerID,
                    accountID: requestedModel.accountID
                )
                return GatewayProxyModelOverride(
                    requestedModel: rewritten,
                    advertisedRequestedModel: requestedModel,
                    variant: nil,
                    alias: alias
                )
            }
        }
        return nil
    }

    enum GatewayModelCatalogClient {
        case generic
        case claudeCode
    }

    func modelCatalogClient(from headers: [String: String]) -> GatewayModelCatalogClient {
        let value = headers["x-openburnbar-client"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return value == "claude-code" ? .claudeCode : .generic
    }

    func advertisedModelID(
        _ routeID: String,
        group: GatewayModelCatalogGroup,
        for client: GatewayModelCatalogClient,
        includeUnadvertised: Bool
    ) -> String {
        guard !includeUnadvertised else { return routeID }
        switch client {
        case .generic:
            return routeID
        case .claudeCode:
            return claudeCodeModelAlias(
                providerID: group.providerID,
                rawModelID: group.representative.id
            )
        }
    }

    func claudeCodeModelAlias(providerID: String, rawModelID: String) -> String {
        let providerScopedRouteID = "\(providerID)/\(rawModelID)"
        return "anthropic.openburnbar.\(Self.base64URLEncode(providerScopedRouteID))"
    }

    func suppressedBaseModelIDs(from snapshot: BurnBarProviderConfigurationSnapshot) -> Set<String> {
        var suppressed = Set<String>()
        for provider in snapshot.providers {
            for alias in provider.modelAliases where alias.hidesBaseModel {
                guard provider.isModelAdvertisementEnabled(alias.aliasID) else { continue }
                let normalizedBase = alias.baseModelID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                guard !normalizedBase.isEmpty else { continue }
                suppressed.insert(normalizedBase)
            }
        }
        return suppressed
    }

    func isSuppressedBaseModelRow(
        _ model: BurnBarLiveAdvertisedModel,
        suppressedBaseIDs: Set<String>
    ) -> Bool {
        guard model.baseModelID == nil, model.thinkingLevel == nil else { return false }
        guard model.sourceKind != "user_model_alias" else { return false }
        let normalizedID = model.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return suppressedBaseIDs.contains(normalizedID)
    }

    func advertisedRouteKeysByFamily(for requestedModel: GatewayRequestedModel) async throws -> [BurnBarProviderFormatFamily: Set<String>] {
        let normalizedModelID = requestedModel.modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedModelID.isEmpty == false else { return [:] }

        let catalog = configStore.catalogSupport.catalog
        // remediation(B1): route through the shared, optionally-cached accessor
        // instead of building a throwaway catalog per call. Now also passes the
        // injected droid process runner (was previously defaulted here), which
        // matches `/v1/models` and is a no-op in production.
        let snapshot = try await catalogSource.snapshot()

        var routeKeysByFamily: [BurnBarProviderFormatFamily: Set<String>] = [:]
        for model in snapshot.models where model.routeEligible && model.advertisementEnabled {
            if let providerID = requestedModel.providerID,
               model.providerID.caseInsensitiveCompare(providerID) != .orderedSame {
                continue
            }
            if let accountID = requestedModel.accountID,
               model.accountID.caseInsensitiveCompare(accountID) != .orderedSame {
                continue
            }
            guard modelMatchesRequested(
                model,
                normalizedRequestedModelID: normalizedModelID,
                providerID: model.providerID,
                catalog: catalog
            ) else {
                continue
            }
            guard await catalogSource.canAdvertise(model, catalog: catalog) else {
                continue
            }
            let family = GatewayModelCatalogSource.formatFamily(for: model, catalog: catalog)
            routeKeysByFamily[family, default: []].insert(
                routeKey(providerID: model.providerID, slotID: model.accountID == "legacy" ? nil : model.accountID)
            )
        }
        if !routeKeysByFamily.isEmpty {
            return routeKeysByFamily
        }

        // Disabled advertisements (including muted aliases) must stay unroutable.
        // Do not resurrect them through namespace/vendor fallback.
        if let configSnapshot = try? await configStore.snapshot() {
            let providersToCheck: [BurnBarProviderSettings]
            if let providerID = requestedModel.providerID {
                providersToCheck = configSnapshot.providers.filter {
                    $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                }
            } else {
                providersToCheck = configSnapshot.providers
            }
            if providersToCheck.contains(where: {
                !$0.isModelAdvertisementEnabled(requestedModel.modelID)
            }) {
                return [:]
            }
        }

        // Ollama `:cloud` / `-cloud` IDs are admitted only by the live catalog page.
        // Dynamic provider fallback must not invent a cloud route that `/search` did not list.
        if OllamaCloudModelRoutingPolicy.cloudAliasBaseModelID(from: normalizedModelID) != nil {
            return routeKeysByFamily
        }

        // Dynamic fallback: If no static advertised row matched, check if an enabled,
        // route-eligible provider exists that can claim or dynamically serve this model
        // (e.g. Anthropic serving dynamic `claude-*` IDs, or OpenAI serving `gpt-*`).
        // A nil claim must not spray the request across every eligible account.
        guard let claimingProviderID = requestedModel.providerID
            ?? configStore.catalogSupport.providerNamespaceClaim(forModelID: normalizedModelID)
            ?? catalog.vendorForModel(named: normalizedModelID)?.id else {
            return routeKeysByFamily
        }
        for account in snapshot.accounts where account.routeEligible {
            if account.providerID.caseInsensitiveCompare(claimingProviderID) != .orderedSame {
                continue
            }
            guard configStore.catalogSupport.modelID(normalizedModelID, isNamespaceSafeFor: account.providerID) else {
                continue
            }
            guard let provider = catalog.provider(id: account.providerID),
                  provider.capabilities.contains(.routing) else {
                continue
            }
            let family = provider.formatFamily
            routeKeysByFamily[family, default: []].insert(
                routeKey(providerID: account.providerID, slotID: account.accountID == "legacy" ? nil : account.accountID)
            )
        }
        return routeKeysByFamily
    }

    func configuredRouteUnavailableRejection(
        clientModelID: String,
        requestedModel: GatewayRequestedModel,
        requestPath: String
    ) async -> (failureMessage: String, response: GatewayHTTPResponse)? {
        let providerID = requestedModel.providerID
            ?? (requestPath == "/v1/messages" ? "anthropic" : nil)
            ?? configStore.catalogSupport.providerNamespaceClaim(forModelID: requestedModel.modelID)
            ?? configStore.catalogSupport.catalog.vendorForModel(named: requestedModel.modelID)?.id
        guard let providerID else { return nil }

        let configSnapshot = try? await configStore.snapshot()
        guard let providerSettings = configSnapshot?.providerSettings(id: providerID),
              providerSettings.isEnabled else {
            return nil
        }

        let accountID = requestedModel.accountID ?? providerSettings.preferredCredentialSlotID
        let selectedSlot = accountID.flatMap { selectedAccountID in
            providerSettings.credentialSlots.first {
                $0.slotID.caseInsensitiveCompare(selectedAccountID) == .orderedSame
            }
        }
        let targetSlots: [BurnBarProviderCredentialSlot]
        if let selectedSlot {
            targetSlots = [selectedSlot]
        } else {
            let enabled = providerSettings.credentialSlots.filter { $0.isEnabled }
            targetSlots = enabled.isEmpty ? providerSettings.credentialSlots : enabled
        }
        guard !targetSlots.isEmpty else { return nil }

        let providerName = configStore.catalogSupport.provider(id: providerID)?.displayName ?? providerID
        let now = Date()

        // 0. Active recent-failure circuit breaker in modelHealthStore
        let formatFamily = requestPath == "/v1/messages" ? BurnBarProviderFormatFamily.anthropic : .openaiCompat
        for slot in targetSlots {
            if let failure = await catalogSource.modelHealthStore.activeFailure(
                modelID: requestedModel.modelID,
                providerID: providerID,
                accountID: slot.slotID,
                formatFamily: formatFamily
            ) {
                let detail = failure.message
                let seconds = max(1, Int(failure.blockedUntil.timeIntervalSince(now)))
                let headers = ["Content-Type": "application/json", "Retry-After": String(seconds)]
                return (
                    failureMessage: "Route temporarily blocked for \(clientModelID): \(failure.message)",
                    response: GatewayHTTPResponse(
                        status: failure.statusCode == 429 ? 429 : 503,
                        headers: headers,
                        body: Data(errorBody(detail).utf8)
                    )
                )
            }
        }

        // 1. All target slots cooling down (e.g. HTTP 429 rate limits)
        let coolingSlots = targetSlots.filter {
            BurnBarProviderCredentialSlotRoutingPolicy.effectiveStatus(for: $0, now: now) == .coolingDown
        }
        if !coolingSlots.isEmpty && coolingSlots.count == targetSlots.count {
            let nextRetry = coolingSlots.compactMap { slot in
                slot.cooldownUntil
                    ?? slot.lastQuotaResetsAt
                    ?? BurnBarProviderCredentialSlotRoutingPolicy.resetDate(from: slot.lastStatusMessage)
            }.min()
            let retrySuffix = nextRetry.map { " Retry after \($0.formatted(date: .abbreviated, time: .standard))." } ?? ""
            let detail = "All configured \(providerName) accounts are temporarily cooling down after receiving rate limit (HTTP 429) responses.\(retrySuffix)"
            var headers = ["Content-Type": "application/json"]
            if let nextRetry {
                let seconds = max(1, Int(nextRetry.timeIntervalSince(now)))
                headers["Retry-After"] = String(seconds)
            }
            return (
                failureMessage: "All configured \(providerName) accounts are cooling down.",
                response: GatewayHTTPResponse(status: 429, headers: headers, body: Data(errorBody(detail).utf8))
            )
        }

        // 2. All target slots exhausted
        let exhaustedSlots = targetSlots.filter {
            BurnBarProviderCredentialSlotRoutingPolicy.effectiveStatus(for: $0, now: now) == .exhausted
        }
        if !exhaustedSlots.isEmpty && exhaustedSlots.count == targetSlots.count {
            let detail = "All configured \(providerName) accounts have exhausted their quota."
            return (
                failureMessage: "All configured \(providerName) accounts are exhausted.",
                response: jsonResponse(status: 429, body: errorBody(detail))
            )
        }

        // 3. All target slots disabled
        if targetSlots.allSatisfy({ !$0.isEnabled }) {
            let detail = "All configured credential slots for \(providerName) are disabled. Enable a slot in OpenBurnBar Settings > Connections."
            return (
                failureMessage: "All configured \(providerName) slots are disabled.",
                response: jsonResponse(status: 503, body: errorBody(detail))
            )
        }

        // 4. Missing secret or authentication failure (401/403)
        let liveSnapshot = try? await catalogSource.snapshot()
        let catalog = configStore.catalogSupport.catalog
        let hasAuthRejection = targetSlots.contains { slot in
            slot.status == .missingSecret || (liveSnapshot?.models.contains { model in
                model.providerID.caseInsensitiveCompare(providerID) == .orderedSame
                    && model.accountID.caseInsensitiveCompare(slot.slotID) == .orderedSame
                    && modelMatchesRequested(
                        model,
                        normalizedRequestedModelID: requestedModel.modelID.lowercased(),
                        providerID: providerID,
                        catalog: catalog
                    )
                    && model.routeEligible == false
                    && Self.isCredentialRejection(model.lastError)
            } == true)
        }
        if hasAuthRejection {
            let accountLabel = selectedSlot?.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountDetail: String
            if let accountLabel, !accountLabel.isEmpty {
                accountDetail = "\(providerName) account '\(accountLabel)'"
            } else {
                accountDetail = providerName
            }
            let isClaudeOAuthSlot = targetSlots.contains {
                $0.authMethodID?.caseInsensitiveCompare("anthropic-claude-oauth") == .orderedSame
                    || $0.slotID.caseInsensitiveCompare("current-claude-code-login") == .orderedSame
            }
            let recovery = isClaudeOAuthSlot
                ? "Run `claude auth login` or reconnect Anthropic in OpenBurnBar Settings > Connections."
                : "Update the API key in OpenBurnBar Settings > Connections."
            let detail = "No eligible route for \(clientModelID) on \(requestPath). "
                + "The configured \(accountDetail) credential is missing or expired. \(recovery)"
            return (
                failureMessage: "Credential unavailable for \(clientModelID).",
                response: jsonResponse(status: 503, body: errorBody(detail))
            )
        }

        return nil
    }

    private static func isCredentialRejection(_ message: String?) -> Bool {
        guard let message = message?.lowercased() else { return false }
        return message.contains("http 401") || message.contains("http 403")
    }

    func resolveAdvertisedRouteKeys(
        requestedModel: GatewayRequestedModel,
        advertisedRequestedModel: GatewayRequestedModel
    ) async throws -> GatewayAdvertisedRouteResolution {
        let primaryKeys = try await advertisedRouteKeysByFamily(for: advertisedRequestedModel)
        if primaryKeys.values.contains(where: { !$0.isEmpty }) {
            return GatewayAdvertisedRouteResolution(
                requestedModel: requestedModel,
                advertisedRequestedModel: advertisedRequestedModel,
                routeKeysByFamily: primaryKeys
            )
        }

        guard let cloudCandidate = legacyOllamaCloudCandidate(for: requestedModel) else {
            return GatewayAdvertisedRouteResolution(
                requestedModel: requestedModel,
                advertisedRequestedModel: advertisedRequestedModel,
                routeKeysByFamily: primaryKeys
            )
        }

        let cloudKeys = try await advertisedRouteKeysByFamily(for: cloudCandidate)
        if cloudKeys.values.contains(where: { !$0.isEmpty }) {
            return GatewayAdvertisedRouteResolution(
                requestedModel: cloudCandidate,
                advertisedRequestedModel: cloudCandidate,
                routeKeysByFamily: cloudKeys
            )
        }

        return GatewayAdvertisedRouteResolution(
            requestedModel: requestedModel,
            advertisedRequestedModel: advertisedRequestedModel,
            routeKeysByFamily: primaryKeys
        )
    }

    func legacyOllamaCloudCandidate(for requestedModel: GatewayRequestedModel) -> GatewayRequestedModel? {
        let requested = requestedModel.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return nil }
        let lowercased = requested.lowercased()
        guard !lowercased.hasSuffix(":cloud"), !lowercased.hasSuffix("-cloud") else {
            return nil
        }
        guard OllamaCloudModelRoutingPolicy.mayClaimModelID(
            requested,
            catalog: configStore.catalogSupport.catalog
        ) else {
            return nil
        }

        let accountID: String?
        if requestedModel.providerID?.caseInsensitiveCompare("ollama") == .orderedSame {
            accountID = requestedModel.accountID
        } else {
            accountID = nil
        }
        return GatewayRequestedModel(
            originalID: requestedModel.originalID,
            modelID: "\(requested):cloud",
            providerID: "ollama",
            accountID: accountID
        )
    }

    func groupedModelCatalogEntries(_ entries: [GatewayModelCatalogEntry]) -> [GatewayModelCatalogGroup] {
        var groupsByKey: [String: GatewayModelCatalogGroup] = [:]
        for entry in entries {
            let providerID = entry.model.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedModelID = entry.model.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !providerID.isEmpty, !normalizedModelID.isEmpty else { continue }
            let key = "\(providerID.lowercased())|\(normalizedModelID)"
            if var group = groupsByKey[key] {
                group.entries.append(entry)
                groupsByKey[key] = group
            } else {
                groupsByKey[key] = GatewayModelCatalogGroup(
                    providerID: providerID,
                    normalizedModelID: normalizedModelID,
                    entries: [entry]
                )
            }
        }
        return groupsByKey.values.sorted { lhs, rhs in
            let lhsModel = lhs.representative
            let rhsModel = rhs.representative
            let providerOrder = lhsModel.providerName.localizedCaseInsensitiveCompare(rhsModel.providerName)
            if providerOrder != .orderedSame {
                return providerOrder == .orderedAscending
            }
            let displayOrder = lhsModel.displayName.localizedCaseInsensitiveCompare(rhsModel.displayName)
            if displayOrder != .orderedSame {
                return displayOrder == .orderedAscending
            }
            return lhsModel.id.localizedCaseInsensitiveCompare(rhsModel.id) == .orderedAscending
        }
    }

    func duplicateAdvertisedModelIDs(in groups: [GatewayModelCatalogGroup]) -> Set<String> {
        let counts = Dictionary(grouping: groups) {
            $0.representative.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return Set(counts.compactMap { key, rows in
            key.isEmpty || rows.count < 2 ? nil : key
        })
    }

    func gatewayRouteModelID(
        for group: GatewayModelCatalogGroup,
        duplicateModelIDs: Set<String>
    ) -> String {
        let rawID = group.representative.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard duplicateModelIDs.contains(rawID.lowercased()) else {
            return rawID
        }
        return "\(group.providerID)/\(rawID)"
    }

    func gatewayRequestedModel(from rawID: String) -> GatewayRequestedModel {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = decodedOpenBurnBarClientAlias(trimmed), decoded != trimmed {
            return gatewayRequestedModel(from: decoded)
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2,
              configStore.catalogSupport.provider(id: parts[0]) != nil else {
            return GatewayRequestedModel(originalID: trimmed, modelID: trimmed, providerID: nil, accountID: nil)
        }

        if parts.count >= 3 {
            let modelID = parts.dropFirst(2).joined(separator: "/")
            if !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return GatewayRequestedModel(
                    originalID: trimmed,
                    modelID: modelID,
                    providerID: parts[0],
                    accountID: parts[1]
                )
            }
        }

        let modelID = parts.dropFirst().joined(separator: "/")
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return GatewayRequestedModel(originalID: trimmed, modelID: trimmed, providerID: nil, accountID: nil)
        }
        return GatewayRequestedModel(originalID: trimmed, modelID: modelID, providerID: parts[0], accountID: nil)
    }

    func decodedOpenBurnBarClientAlias(_ rawID: String) -> String? {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("openburnbar/") {
            let routeID = String(trimmed.dropFirst("openburnbar/".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return routeID.isEmpty ? nil : routeID
        }

        let prefix = "anthropic.openburnbar."
        guard trimmed.lowercased().hasPrefix(prefix) else { return nil }
        let encoded = String(trimmed.dropFirst(prefix.count))
        guard let decoded = Self.base64URLDecode(encoded)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !decoded.isEmpty else {
            return nil
        }
        return decoded
    }

    static func base64URLEncode(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func preferredGatewayFormatFamilies(
        for modelID: String,
        advertised: [BurnBarProviderFormatFamily: Set<String>]
    ) -> [BurnBarProviderFormatFamily] {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let baseOrder: [BurnBarProviderFormatFamily] = normalized.contains("claude") || normalized.contains("anthropic")
            ? [.anthropic, .openaiCompat]
            : [.openaiCompat, .anthropic]
        return baseOrder.filter { advertised[$0]?.isEmpty == false }
    }

    func singleAdvertisedProviderID(
        in advertised: [BurnBarProviderFormatFamily: Set<String>]
    ) -> String? {
        var providerIDs: Set<String> = []
        for routeKeys in advertised.values {
            for routeKey in routeKeys {
                let providerID = routeKey
                    .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                    .first
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let providerID, !providerID.isEmpty {
                    providerIDs.insert(providerID)
                }
            }
        }
        return providerIDs.count == 1 ? providerIDs.first : nil
    }

    func modelMatchesRequested(
        _ model: BurnBarLiveAdvertisedModel,
        normalizedRequestedModelID: String,
        providerID: String,
        catalog: BurnBarCatalog
    ) -> Bool {
        if advertisedModel(
            model.id,
            matchesRequestedModelID: normalizedRequestedModelID,
            providerID: providerID,
            catalog: catalog
        ) {
            return true
        }
        if let baseModelID = model.baseModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !baseModelID.isEmpty,
           baseModelID == normalizedRequestedModelID {
            return true
        }
        return false
    }

    func advertisedModel(
        _ advertisedModelID: String,
        matchesRequestedModelID normalizedRequestedModelID: String,
        providerID: String,
        catalog: BurnBarCatalog
    ) -> Bool {
        let normalizedAdvertisedModelID = advertisedModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedRequestedModelID = normalizedRequestedModelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedAdvertisedModelID.isEmpty, !normalizedRequestedModelID.isEmpty else { return false }
        if normalizedAdvertisedModelID == normalizedRequestedModelID {
            return true
        }

        let supportsOllamaCloudAliases = providerID.caseInsensitiveCompare("ollama") == .orderedSame
        let advertisedCloudID = supportsOllamaCloudAliases
            ? OllamaCloudModelRoutingPolicy.canonicalCloudModelID(normalizedAdvertisedModelID)
            : nil
        let requestedCloudID = supportsOllamaCloudAliases
            ? OllamaCloudModelRoutingPolicy.canonicalCloudModelID(normalizedRequestedModelID)
            : nil
        if let advertisedCloudID, let requestedCloudID, advertisedCloudID == requestedCloudID {
            return true
        }
        if supportsOllamaCloudAliases, (advertisedCloudID != nil) != (requestedCloudID != nil) {
            return false
        }
        if !supportsOllamaCloudAliases,
           normalizedAdvertisedModelID.hasSuffix(":cloud") != normalizedRequestedModelID.hasSuffix(":cloud") {
            return false
        }

        return catalog.models(forProviderID: providerID).contains { model in
            let explicitModelIDs = Set(([model.id] + model.aliases).flatMap { rawID -> [String] in
                let normalized = rawID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { return [] }
                if supportsOllamaCloudAliases,
                   let cloudID = OllamaCloudModelRoutingPolicy.canonicalCloudModelID(normalized) {
                    return [normalized, cloudID]
                }
                return [normalized]
            })
            let requestedID = requestedCloudID ?? normalizedRequestedModelID
            let advertisedID = advertisedCloudID ?? normalizedAdvertisedModelID
            let matchesRequested = explicitModelIDs.contains(requestedID) || model.matches(modelName: requestedID)
            let matchesAdvertised = explicitModelIDs.contains(advertisedID) || model.matches(modelName: advertisedID)
            return matchesRequested && matchesAdvertised
        }
    }

}
