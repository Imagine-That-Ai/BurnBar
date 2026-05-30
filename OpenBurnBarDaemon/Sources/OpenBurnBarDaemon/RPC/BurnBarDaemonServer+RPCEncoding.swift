import OpenBurnBarCore
import Foundation

extension BurnBarDaemonServer {
    func encode<Result: Codable & Sendable>(_ envelope: BurnBarRPCResponseEnvelope<Result>) -> Data {
        do {
            let encoder = JSONEncoder()
            return try encoder.encode(envelope)
        } catch {
            logger.error(
                "rpc_encode_failed",
                metadata: ["error": "\(error)"]
            )
            return encodeErrorResponse(
                id: envelope.id,
                code: BurnBarRPCErrorCode.internalError,
                message: "Failed to encode OpenBurnBar RPC response."
            )
        }
    }

    func encodeErrorResponse(id: String, code: Int, message: String) -> Data {
        let envelope = BurnBarRPCResponseEnvelope<BurnBarEmptyResult>(
            id: id,
            protocolVersion: BurnBarProtocolVersion.current,
            result: nil,
            error: BurnBarRPCError(code: code, message: message)
        )

        let encoder = JSONEncoder()
        do {
            return try encoder.encode(envelope)
        } catch {
            logger.error(
                "encode_error_response_failed",
                metadata: ["id": id, "code": "\(code)", "message": message, "error": "\(error)"]
            )
            let fallback = ["error": ["code": code, "message": "Internal encoding error"]] as [String: Any]
            do {
                return try JSONSerialization.data(withJSONObject: fallback)
            } catch {
                logger.silentFailure("encode_fallback_error_response", error: error)
                return Data()
            }
        }
    }
}
