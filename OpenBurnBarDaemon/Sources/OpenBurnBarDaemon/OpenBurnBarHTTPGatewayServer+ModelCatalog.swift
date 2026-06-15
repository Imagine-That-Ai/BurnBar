import OpenBurnBarCore
import CryptoKit
import Foundation
import Network

// /v1/models catalog + advertisement.
// Extracted from OpenBurnBarHTTPGatewayServer.swift (god-type decomposition) — same module, same isolation, verbatim.

extension BurnBarHTTPGatewayServer {

    /// remediation(B1): single, shared accessor for the expensive live
    /// model-catalog snapshot used by BOTH `handleModels` (`/v1/models`) and the
    /// routing path (`advertisedRouteKeysByFamily`). When `modelCatalogCacheTTL`
    /// is positive, a snapshot is reused while it is fresh AND the config
    /// snapshot is unchanged; otherwise it falls through to an uncached build
    /// that is byte-identical to the previous per-call behavior. Runs inside the
    /// actor's isolation, so the cache read/refresh is race-free.
    func liveModelCatalogSnapshot() async throws -> BurnBarLiveModelCatalogSnapshot {
        // The config snapshot is cheap (config store memoizes it) and changes
        // whenever provider config/credentials change, so its identity is the
        // natural cache key — a config edit invalidates the cache immediately.
        let configHash = (try? await configStore.snapshot())?.hashValue
        if modelCatalogCacheTTL > 0,
           let cached = cachedModelCatalog,
           let configHash,
           cached.configHash == configHash,
           Date().timeIntervalSince(cached.storedAt) < modelCatalogCacheTTL {
            return cached.snapshot
        }
        let snapshot = try await BurnBarLiveModelCatalog(
            configStore: configStore,
            session: modelCatalogSession,
            droidProcessRunner: modelCatalogDroidProcessRunner
        ).snapshot()
        if modelCatalogCacheTTL > 0, let configHash {
            cachedModelCatalog = CachedModelCatalogSnapshot(
                configHash: configHash,
                storedAt: Date(),
                snapshot: snapshot
            )
        }
        return snapshot
    }

    func handleModels(includeUnadvertised: Bool = false) async -> GatewayHTTPResponse {
        do {
            let catalog = configStore.catalogSupport.catalog
            let configSnapshot = try await configStore.snapshot()
            let suppressedBaseIDs = includeUnadvertised
                ? Set<String>()
                : suppressedBaseModelIDs(from: configSnapshot)
            let snapshot = try await liveModelCatalogSnapshot()
            var entries: [GatewayModelCatalogEntry] = []
            for model in snapshot.models {
                if !includeUnadvertised,
                   isSuppressedBaseModelRow(model, suppressedBaseIDs: suppressedBaseIDs) {
                    continue
                }
                let canAdvertise = await canAdvertiseModel(model, catalog: catalog)
                let advertised = model.routeEligible && model.advertisementEnabled && canAdvertise
                if advertised || (includeUnadvertised && model.enabled) {
                    entries.append(GatewayModelCatalogEntry(model: model, advertised: advertised))
                }
            }
            let groups = groupedModelCatalogEntries(entries)
            let duplicateModelIDs = duplicateAdvertisedModelIDs(in: groups)
            let models = groups.map { group in
                ModelDescriptor(
                    group: group,
                    advertisedID: gatewayRouteModelID(for: group, duplicateModelIDs: duplicateModelIDs)
                )
            }
            return jsonResponse(status: 200, body: encodeBody(ModelsResponse(data: models)))
        } catch {
            logger.error("gateway_models_error", metadata: ["error": "\(error)"])
            return jsonResponse(status: 500, body: errorBody("internal error"))
        }
    }

    func canAdvertiseModel(
        _ model: BurnBarLiveAdvertisedModel,
        catalog: BurnBarCatalog
    ) async -> Bool {
        let formatFamily = advertisedFormatFamily(for: model, catalog: catalog)
        if let failure = await modelHealthStore.activeFailure(
            modelID: model.id,
            providerID: model.providerID,
            accountID: model.accountID,
            formatFamily: formatFamily
        ) {
            logger.warning(
                "gateway_models_route_recently_failed",
                metadata: [
                    "model": model.id,
                    "provider": model.providerID,
                    "account": model.accountID,
                    "status": "\(failure.statusCode)",
                    "blocked_until": "\(failure.blockedUntil)"
                ]
            )
            return false
        }
        return true
    }

    func canRouteAdvertisedModel(
        _ model: BurnBarLiveAdvertisedModel,
        router: BurnBarProviderRouter,
        catalog: BurnBarCatalog
    ) async -> Bool {
        guard await canAdvertiseModel(model, catalog: catalog) else { return false }

        let formatFamily = advertisedFormatFamily(for: model, catalog: catalog)
        let expectedRouteKey = routeKey(
            providerID: model.providerID,
            slotID: model.accountID == "legacy" ? nil : model.accountID
        )
        do {
            let ranking = try await router.scoreAndRankRoutes(
                modelName: model.id,
                requestedFormatFamily: formatFamily,
                requiredCanonicalModelID: canonicalModelID(
                    forModelName: model.id,
                    providerID: model.providerID,
                    catalog: catalog
                )
            )
            return ranking.rankedRoutes.contains { rankedRoute in
                routeKey(
                    providerID: rankedRoute.route.providerID,
                    slotID: rankedRoute.route.credentialSlotID
                ) == expectedRouteKey
            }
        } catch {
            logger.warning(
                "gateway_models_route_unavailable",
                metadata: [
                    "model": model.id,
                    "provider": model.providerID,
                    "account": model.accountID,
                    "error": "\(error)"
                ]
            )
            return false
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
        let snapshot = try await liveModelCatalogSnapshot()

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
            guard await canAdvertiseModel(model, catalog: catalog) else {
                continue
            }
            let family = advertisedFormatFamily(for: model, catalog: catalog)
            routeKeysByFamily[family, default: []].insert(
                routeKey(providerID: model.providerID, slotID: model.accountID == "legacy" ? nil : model.accountID)
            )
        }
        return routeKeysByFamily
    }

    struct GatewayAdvertisedRouteResolution {
        let requestedModel: GatewayRequestedModel
        let advertisedRequestedModel: GatewayRequestedModel
        let routeKeysByFamily: [BurnBarProviderFormatFamily: Set<String>]
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
        guard cloudKeys.values.contains(where: { !$0.isEmpty }) else {
            return GatewayAdvertisedRouteResolution(
                requestedModel: requestedModel,
                advertisedRequestedModel: advertisedRequestedModel,
                routeKeysByFamily: primaryKeys
            )
        }
        return GatewayAdvertisedRouteResolution(
            requestedModel: cloudCandidate,
            advertisedRequestedModel: cloudCandidate,
            routeKeysByFamily: cloudKeys
        )
    }

    func legacyOllamaCloudCandidate(for requestedModel: GatewayRequestedModel) -> GatewayRequestedModel? {
        let requested = requestedModel.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else { return nil }
        let lowercased = requested.lowercased()
        guard !lowercased.hasSuffix(":cloud"), !lowercased.hasSuffix("-cloud") else {
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

    struct GatewayRequestedModel {
        let originalID: String
        let modelID: String
        let providerID: String?
        let accountID: String?
    }
    func gatewayRequestedModel(from rawID: String) -> GatewayRequestedModel {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func advertisedFormatFamily(
        for model: BurnBarLiveAdvertisedModel,
        catalog: BurnBarCatalog
    ) -> BurnBarProviderFormatFamily {
        if model.capabilities.contains(BurnBarProviderFormatFamily.anthropic.rawValue) {
            return .anthropic
        }
        if model.capabilities.contains(BurnBarProviderFormatFamily.openaiCompat.rawValue) {
            return .openaiCompat
        }
        return catalog.provider(id: model.providerID)?.formatFamily ?? .openaiCompat
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
        guard !normalizedAdvertisedModelID.isEmpty else { return false }
        if normalizedAdvertisedModelID == normalizedRequestedModelID {
            return true
        }

        if normalizedAdvertisedModelID.hasSuffix(":cloud") != normalizedRequestedModelID.hasSuffix(":cloud") {
            return false
        }

        return catalog.models(forProviderID: providerID).contains { model in
            let explicitModelIDs = Set(([model.id] + model.aliases).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            })
            return explicitModelIDs.contains(normalizedRequestedModelID)
                && explicitModelIDs.contains(normalizedAdvertisedModelID)
        }
    }
}
