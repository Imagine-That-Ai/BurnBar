import Foundation
import OpenBurnBarEngine

extension BurnBarDaemonServer {
    /// AI Inbox RPCs.
    ///
    /// Reads are `observability`-scoped (the same posture as usage/insight
    /// reads: already-synthesized, already-redacted summaries plus
    /// reference-shaped evidence). Config writes and `run_now` are
    /// `config`-scoped because they change the egress posture, the spend
    /// ceiling, or immediately spend money.
    func handleInboxRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        request: BurnBarRPCRequestEnvelope,
        requestData: Data
    ) async throws -> Data {
        // Config reads force a retry so Settings → Retry can recover after a
        // transient lock or after the encryption key becomes readable.
        let forceRetry = method == .inboxConfigGet
        guard let inbox = ensureAIInboxBootstrapped(forceRetry: forceRetry) else {
            let message = aiInboxUnavailabilityReason
                ?? "The AI Inbox is not available. Configure OPENBURNBAR_INDEX_DATABASE_PATH and restart the daemon."
            return encodeErrorResponse(
                id: request.id,
                code: BurnBarRPCErrorCode.internalError,
                message: message
            )
        }

        switch method {
        case .inboxList:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxListRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.list(typedRequest.params)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxGet:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxGetRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: BurnBarInboxGetResponse(item: try await inbox.item(id: typedRequest.params.id))
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxRunsRecent:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxRunsRequest>.self,
                from: requestData
            )
            do {
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: typedRequest.id,
                        result: try await inbox.recentRuns(limit: typedRequest.params.limit)
                    )
                )
            } catch {
                return encodeErrorResponse(
                    id: typedRequest.id,
                    code: BurnBarRPCErrorCode.internalError,
                    message: error.localizedDescription
                )
            }

        case .inboxConfigGet:
            return encode(
                BurnBarRPCResponseEnvelope(id: request.id, result: await inbox.configuration())
            )

        case .inboxConfigUpdate:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxConfig>.self,
                from: requestData
            )
            // The service normalizes/clamps and returns what it actually stored,
            // so the caller can render the effective values rather than assume
            // its request was accepted verbatim.
            let stored = await inbox.updateConfiguration(typedRequest.params)
            return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: stored))

        case .inboxRunNow:
            let typedRequest = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarInboxRunNowRequest>.self,
                from: requestData
            )
            let response = await inbox.runNow(force: typedRequest.params.force)
            return encode(BurnBarRPCResponseEnvelope(id: typedRequest.id, result: response))

        default:
            preconditionFailure("Unhandled inbox RPC method: \(method.rawValue)")
        }
    }
}
