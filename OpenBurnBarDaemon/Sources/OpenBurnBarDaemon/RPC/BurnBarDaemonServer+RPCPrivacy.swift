import Foundation
import OpenBurnBarCore

#if os(Linux)
extension BurnBarDaemonServer {
    func handleLinuxPrivacyRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .linuxPrivacyInventory:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            let inventory = await linuxPrivacyService.inventory()
            let result = BurnBarLinuxPrivacyInventoryResponse(
                stores: inventory.stores.map {
                    BurnBarLinuxPrivacyStoreInventory(
                        store: $0.store,
                        state: $0.state,
                        bytes: $0.bytes,
                        reason: $0.reason
                    )
                },
                generatedAt: inventory.generatedAt
            )
            return encode(BurnBarRPCResponseEnvelope(id: request.id, result: result))
        case .linuxPrivacyDeletionPreview:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarLinuxPrivacyDeletionPreviewRequest>.self,
                from: requestData
            )
            let preview = try await linuxPrivacyService.previewDeletion(stores: request.params.stores)
            let result = BurnBarLinuxPrivacyDeletionPreviewResponse(
                token: preview.token,
                stores: preview.stores,
                entries: preview.entries.map {
                    BurnBarLinuxPrivacyStoreInventory(
                        store: $0.store,
                        state: $0.state,
                        bytes: $0.bytes,
                        reason: $0.reason
                    )
                },
                expiresAt: preview.expiresAt,
                confirmationPhrase: preview.confirmationPhrase
            )
            return encode(BurnBarRPCResponseEnvelope(id: request.id, result: result))
        case .linuxPrivacyDeletionExecute:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarLinuxPrivacyDeletionExecuteRequest>.self,
                from: requestData
            )
            let result = try await linuxPrivacyService.executeDeletion(
                .init(
                    token: request.params.token,
                    stores: request.params.stores,
                    confirmation: request.params.confirmation
                )
            )
            return encode(
                BurnBarRPCResponseEnvelope(
                    id: request.id,
                    result: BurnBarLinuxPrivacyDeletionExecuteResponse(
                        stores: result.stores,
                        deleted: result.deleted,
                        alreadyAbsent: result.alreadyAbsent,
                        bytesRemoved: result.bytesRemoved,
                        idempotent: result.idempotent
                    )
                )
            )
        case .linuxPrivacyExport:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarLinuxPrivacyExportRequest>.self,
                from: requestData
            )
            let result = try await linuxPrivacyService.export(request.params)
            return encode(BurnBarRPCResponseEnvelope(id: request.id, result: result))
        case .linuxPrivacyRetentionStatus:
            let request = try decoder.decode(BurnBarRPCRequestEnvelope.self, from: requestData)
            let result = try await linuxPrivacyService.retentionStatus()
            return encode(BurnBarRPCResponseEnvelope(id: request.id, result: result))
        case .linuxPrivacyRetentionApply:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarLinuxPrivacyRetentionApplyRequest>.self,
                from: requestData
            )
            let result = try await linuxPrivacyService.applyRetention(request.params)
            return encode(BurnBarRPCResponseEnvelope(id: request.id, result: result))
        default:
            preconditionFailure("Unhandled Linux privacy RPC method: \(method.rawValue)")
        }
    }
}
#endif
