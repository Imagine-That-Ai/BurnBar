import OpenBurnBarCore
import Foundation

extension BurnBarDaemonServer {
    func handleConfigRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .configGet:
            let typedRequest = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            _ = BurnBarConfigGetRequest()
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarConfigResponse(snapshot: try await configStore.snapshot())
            )
            return encode(response)
        case .configUpdate:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarConfigUpdateRequest>.self,
                from: requestData
            )
            let snapshot = try await configStore.replaceSnapshot(typedRequest.params.snapshot)
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarConfigResponse(snapshot: snapshot)
            )
            return encode(response)
        case .providerCredentialSlotUpsert:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProviderCredentialSlotUpsertRequest>.self,
                from: requestData
            )
            let slot = try await configStore.upsertCredentialSlot(
                providerID: typedRequest.params.providerID,
                slotID: typedRequest.params.slotID,
                label: typedRequest.params.label,
                apiKey: typedRequest.params.apiKey,
                isEnabled: typedRequest.params.isEnabled,
                endpointProfileID: typedRequest.params.endpointProfileID,
                region: typedRequest.params.region,
                tokenPlanTier: typedRequest.params.tokenPlanTier,
                tokenPlanBillingCycle: typedRequest.params.tokenPlanBillingCycle,
                authMethodID: typedRequest.params.authMethodID
            )
            let snapshot = try await configStore.snapshot()
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProviderCredentialSlotMutationResponse(
                    snapshot: snapshot,
                    slot: slot
                )
            )
            return encode(response)
        case .providerCredentialSlotRemove:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProviderCredentialSlotRemoveRequest>.self,
                from: requestData
            )
            try await configStore.removeCredentialSlot(
                providerID: typedRequest.params.providerID,
                slotID: typedRequest.params.slotID
            )
            let snapshot = try await configStore.snapshot()
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProviderCredentialSlotMutationResponse(snapshot: snapshot)
            )
            return encode(response)
        case .providerModelVariantUpsert:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProviderModelVariantUpsertRequest>.self,
                from: requestData
            )
            let variant = try await configStore.upsertModelVariant(
                providerID: typedRequest.params.providerID,
                variant: typedRequest.params.variant
            )
            let snapshot = try await configStore.snapshot()
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProviderModelVariantMutationResponse(
                    snapshot: snapshot,
                    variant: variant
                )
            )
            return encode(response)
        case .providerModelVariantRemove:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProviderModelVariantRemoveRequest>.self,
                from: requestData
            )
            try await configStore.removeModelVariant(
                providerID: typedRequest.params.providerID,
                variantID: typedRequest.params.variantID
            )
            let snapshot = try await configStore.snapshot()
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProviderModelVariantMutationResponse(snapshot: snapshot)
            )
            return encode(response)
        case .providerModelAliasUpsert:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProviderModelAliasUpsertRequest>.self,
                from: requestData
            )
            let alias = try await configStore.upsertModelAlias(
                providerID: typedRequest.params.providerID,
                alias: typedRequest.params.alias
            )
            let aliasSnapshot = try await configStore.snapshot()
            let aliasResponse = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProviderModelAliasMutationResponse(
                    snapshot: aliasSnapshot,
                    alias: alias
                )
            )
            return encode(aliasResponse)
        case .providerModelAliasRemove:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProviderModelAliasRemoveRequest>.self,
                from: requestData
            )
            try await configStore.removeModelAlias(
                providerID: typedRequest.params.providerID,
                aliasID: typedRequest.params.aliasID
            )
            let removedAliasSnapshot = try await configStore.snapshot()
            let removedAliasResponse = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProviderModelAliasMutationResponse(snapshot: removedAliasSnapshot)
            )
            return encode(removedAliasResponse)
        case .providerModelDisplayNameSet:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProviderModelDisplayNameSetRequest>.self,
                from: requestData
            )
            let override = try await configStore.setModelDisplayName(
                providerID: typedRequest.params.providerID,
                modelID: typedRequest.params.modelID,
                displayName: typedRequest.params.displayName
            )
            let snapshot = try await configStore.snapshot()
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProviderModelDisplayNameMutationResponse(
                    override: override,
                    snapshot: snapshot
                )
            )
            return encode(response)
        case .providerModelDisplayNameClear:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarProviderModelDisplayNameClearRequest>.self,
                from: requestData
            )
            try await configStore.clearModelDisplayName(
                providerID: typedRequest.params.providerID,
                modelID: typedRequest.params.modelID
            )
            let snapshot = try await configStore.snapshot()
            let response = BurnBarRPCResponseEnvelope(
                id: typedRequest.id,
                protocolVersion: BurnBarProtocolVersion.current,
                result: BurnBarProviderModelDisplayNameMutationResponse(
                    override: nil,
                    snapshot: snapshot
                )
            )
            return encode(response)
        default:
            preconditionFailure("Unhandled config RPC method: \(method.rawValue)")
        }
    }
}
