import Foundation

/// Marks decoding performed to validate a method request shape. A plain
/// DecodingError from a handler (for example, corrupt persisted config) must
/// remain a daemon-side failure and map to internalError.
struct BurnBarRPCRequestShapeDecodingError: Error, LocalizedError {
    let underlying: Error

    var errorDescription: String? {
        underlying.localizedDescription
    }
}

extension BurnBarDaemonServer {
    func decodeRequest<T: Decodable>(
        _ type: T.Type,
        from requestData: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        do {
            return try decoder.decode(type, from: requestData)
        } catch let error as DecodingError {
            throw BurnBarRPCRequestShapeDecodingError(underlying: error)
        } catch {
            throw error
        }
    }
}
