import BurnBarCore
import Foundation

/// Documented error codes for the RPC error envelope matrix (VAL-RPC-016).
/// Every failure class returns its exact code; the matrix is documented in
/// `docs/fleet/BURNBAR_FLEET_SIGNALS.md` ("RPC transport & error envelope
/// matrix").
enum BurnBarRPCErrorCode {
    /// Malformed JSON payload (not decodable as a JSON object).
    static let parseError = -32700
    /// Valid JSON whose envelope shape is invalid (missing/wrong-typed id or method).
    static let invalidRequest = -32600
    /// Unknown method.
    static let methodNotFound = -32601
    /// Typed params decode failure.
    static let invalidParams = -32602
    /// Daemon-side failure (e.g. fleet not ready, search unavailable).
    static let internalError = -32603
    /// Declared `protocolVersion` is outside the supported set (VAL-RPC-012).
    static let protocolVersionMismatch = -32001
    /// Frame exceeds the 64KB payload cap (VAL-RPC-004).
    static let frameTooLarge = -32002
}

/// Minimal id-only probe used to recover a request id when the full envelope
/// failed to decode (e.g. a missing `method`). A wrong-typed `id` (non-string)
/// fails this probe too, so the documented no-id sentinel is used instead.
private struct IncomingRequestIDProbe: Decodable {
    let id: String?
}

private struct BurnBarEmptyResult: Codable, Sendable {}

/// Builds the typed error envelopes shared by every RPC failure class
/// (VAL-RPC-016). The `details` field is ALWAYS encoded (non-optional) and
/// carries machine-actionable, never-secret-bearing context: byte counts for
/// oversized frames, the expected envelope shape for invalid requests,
/// declared vs supported versions for protocol mismatches.
enum BurnBarRPCErrorEnvelope {
    /// Documented id used in error envelopes when the request id is absent or
    /// not syntactically recoverable (VAL-RPC-011/016). The daemon never
    /// fabricates a client-supplied id.
    static let noRequestID = "no-id"

    /// True when the frame is syntactically valid JSON (any shape, including
    /// top-level fragments). `.fragmentsAllowed` is required: else valid
    /// fragments are misclassified as parse errors.
    static func isValidJSONObject(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    /// Recovers the request id from a partially decoded frame: the full
    /// envelope decode failed, so a minimal id-only probe decides whether the
    /// id is syntactically recoverable. Returns the documented no-id
    /// sentinel when the id is absent or wrong-typed.
    static func recoverRequestID(from requestData: Data) -> String {
        if let probe = try? JSONDecoder().decode(IncomingRequestIDProbe.self, from: requestData),
           let id = probe.id {
            return id
        }
        return BurnBarRPCErrorEnvelope.noRequestID
    }

    /// Encodes one typed error envelope line: protocol version 1, the request
    /// id (or the no-id sentinel), no result, and an `error` object with the
    /// enumerated code, a non-empty message, and non-empty machine-actionable
    /// details.
    static func encodeErrorResponse(id: String, code: Int, message: String, details: String) -> Data {
        let envelope = BurnBarRPCResponseEnvelope<BurnBarEmptyResult>(
            id: id,
            protocolVersion: BurnBarProtocolVersion.current,
            result: nil,
            error: BurnBarRPCError(code: code, message: message, details: details)
        )
        let encoder = JSONEncoder()
        return (try? encoder.encode(envelope)) ?? Data()
    }
}
