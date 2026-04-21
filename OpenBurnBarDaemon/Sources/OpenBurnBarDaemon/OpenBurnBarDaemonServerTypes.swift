import OpenBurnBarCore
import Foundation

// Socket/RPC envelope types shared by `BurnBarDaemonServer` (actor implementation stays in BurnBarDaemonServer.swift).

public enum BurnBarDaemonError: Error, LocalizedError {
    case socketPathTooLong(String)
    case unexpectedExistingItem(String)
    case failedToCreateSocket(code: Int32, detail: String)
    case failedToBindSocket(path: String, code: Int32, detail: String)
    case failedToListen(path: String, code: Int32, detail: String)
    case failedToCreateParentDirectory(String)
    case requestTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path):
            return "OpenBurnBar socket path exceeds sockaddr_un capacity: \(path)"
        case .unexpectedExistingItem(let path):
            return "OpenBurnBar socket path already exists with an unsupported file type: \(path)"
        case .failedToCreateSocket(let code, let detail):
            return "Failed to create OpenBurnBar daemon socket (\(code)): \(detail)"
        case .failedToBindSocket(let path, let code, let detail):
            return "Failed to bind OpenBurnBar daemon socket at \(path) (\(code)): \(detail)"
        case .failedToListen(let path, let code, let detail):
            return "Failed to listen on OpenBurnBar daemon socket at \(path) (\(code)): \(detail)"
        case .failedToCreateParentDirectory(let path):
            return "Failed to create OpenBurnBar daemon socket directory: \(path)"
        case .requestTooLarge(let maxBytes):
            return "OpenBurnBar daemon request exceeded the maximum size of \(maxBytes) bytes."
        }
    }
}

enum BurnBarRPCErrorCode {
    static let invalidRequest = -32600
    static let invalidParams = -32602
    static let methodNotFound = -32601
    static let internalError = -32603
    static let unauthorized = -32001
}

struct IncomingRequestEnvelope: Decodable {
    let id: String
    let method: String
    let authToken: String?
}

struct BurnBarEmptyResult: Codable, Sendable {}
