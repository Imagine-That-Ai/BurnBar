import Foundation
import OpenBurnBarEngine

extension BurnBarDaemonServer {
    func handleChatRPC(
        method: BurnBarRPCMethod,
        decoder: JSONDecoder,
        requestData: Data
    ) async throws -> Data {
        switch method {
        case .chatThreadList:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarChatThreadListRequest>.self,
                from: requestData
            )
            guard let chatThreadService else {
                return chatUnavailableResponse(id: request.id)
            }
            do {
                let result = try await chatThreadService.listThreads(request.params)
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: request.id,
                        protocolVersion: BurnBarProtocolVersion.current,
                        result: result
                    )
                )
            } catch {
                return chatErrorResponse(id: request.id, error: error)
            }

        case .chatThreadGet:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarChatThreadGetRequest>.self,
                from: requestData
            )
            guard let chatThreadService else {
                return chatUnavailableResponse(id: request.id)
            }
            do {
                let result = try await chatThreadService.getThread(request.params)
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: request.id,
                        protocolVersion: BurnBarProtocolVersion.current,
                        result: result
                    )
                )
            } catch {
                return chatErrorResponse(id: request.id, error: error)
            }

        case .chatMessageAppend:
            let request = try decoder.decode(
                BurnBarRPCRequestEnvelopeWithParams<BurnBarChatMessageAppendRequest>.self,
                from: requestData
            )
            guard let chatThreadService else {
                return chatUnavailableResponse(id: request.id)
            }
            do {
                let result = try await chatThreadService.appendMessage(request.params)
                return encode(
                    BurnBarRPCResponseEnvelope(
                        id: request.id,
                        protocolVersion: BurnBarProtocolVersion.current,
                        result: result
                    )
                )
            } catch {
                return chatErrorResponse(id: request.id, error: error)
            }

        default:
            preconditionFailure("Unhandled chat RPC method: \(method.rawValue)")
        }
    }

    private func chatUnavailableResponse(id: String) -> Data {
        encodeErrorResponse(
            id: id,
            code: BurnBarRPCErrorCode.unavailable,
            message: "Canonical local chat history is unavailable. Configure the OpenBurnBar database path and restart the daemon."
        )
    }

    private func chatErrorResponse(id: String, error: Error) -> Data {
        let code: Int
        let message: String
        switch error {
        case BurnBarChatThreadServiceError.invalidRequest(let detail):
            code = BurnBarRPCErrorCode.invalidParams
            message = "Invalid chat request: \(detail)"
        case BurnBarChatThreadServiceError.conflict(let detail):
            code = BurnBarRPCErrorCode.conflict
            message = "Chat history conflict: \(detail)"
        case BurnBarChatThreadServiceError.unavailable(let detail):
            code = BurnBarRPCErrorCode.unavailable
            message = "Chat history unavailable: \(detail)"
        case BurnBarChatThreadServiceError.corruptData(_):
            code = BurnBarRPCErrorCode.internalError
            message = "Canonical local chat history contains invalid data."
        case BurnBarChatThreadServiceError.database(_):
            code = BurnBarRPCErrorCode.internalError
            message = "Canonical local chat history could not be read or updated."
        default:
            code = BurnBarRPCErrorCode.internalError
            message = "Canonical local chat history request failed."
        }
        logger.error(
            "chat_rpc_failed",
            metadata: ["request_id": id, "error": "\(error)"]
        )
        return encodeErrorResponse(id: id, code: code, message: message)
    }
}
