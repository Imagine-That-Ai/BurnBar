import Foundation
import Combine
import Darwin
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import OpenBurnBarMedia
import OSLog
import AppKit
import ImageIO

// Mercury remote-access agent client, request/response types, and sealing errors.
// Extracted from MercuryRouter.swift (god-file decomposition) — same module, verbatim.

struct MercuryRemoteAccessAgentClient: Sendable {
    static let socketPath = "/var/run/openburnbar-remote-access-agent.sock"
    static let maximumResponseBytes = 16 * 1024
    static let requestIOTimeoutSeconds: time_t = 3

    /// Blocking socket send runs off the main actor: this is a `nonisolated`
    /// `async` method (the type is `Sendable`), so callers leave the main actor at
    /// the `await` (SE-0338).
    func wakeDisplay() async throws {
        try Self.send(MercuryRemoteAccessAgentRequest(operation: "wakeDisplay", password: nil))
    }

    static func send(_ request: MercuryRemoteAccessAgentRequest) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MercuryRemoteAccessAgentClientError.socketUnavailable }
        defer { close(fd) }
        configureSocket(fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketPath.withCString { path in
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard strlen(path) < capacity else { throw MercuryRemoteAccessAgentClientError.socketPathTooLong }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    strncpy(destination, path, capacity - 1)
                }
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw MercuryRemoteAccessAgentClientError.daemonUnavailable }

        var data = try JSONEncoder().encode(request)
        data.append(0x0a)
        try data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw MercuryRemoteAccessAgentClientError.timedOut }
                    throw MercuryRemoteAccessAgentClientError.writeFailed
                }
                written += count
            }
        }
        shutdown(fd, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw MercuryRemoteAccessAgentClientError.timedOut }
                throw MercuryRemoteAccessAgentClientError.readFailed
            }
            responseData.append(buffer, count: count)
            if responseData.count > maximumResponseBytes { throw MercuryRemoteAccessAgentClientError.responseTooLarge }
        }
        guard let response = try? JSONDecoder().decode(MercuryRemoteAccessAgentResponse.self, from: responseData), // try?-ok(malformed fails closed)
              response.ok else {
            throw MercuryRemoteAccessAgentClientError.daemonRejected
        }
    }

    static func configureSocket(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: requestIOTimeoutSeconds, tv_usec: 0)
        let length = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, length)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, length)
    }
}

struct MercuryRemoteAccessAgentRequest: Encodable, Sendable {
    var operation: String
    var password: String?
}

struct MercuryRemoteAccessAgentResponse: Decodable, Sendable {
    var ok: Bool
}

/// F7 — thrown when `MediaFrameAeadNegotiation` refuses a lane because sealing
/// was expected but could not be established. Surfaced to the viewer as an
/// `.unsupported` mirror ack (via `failAcceptedMirrorRuntime`) so a de-negotiated
/// peer sees a clean "media unavailable" banner instead of the lane silently
/// degrading to plaintext-over-QUIC.
enum MercuryLaneSealingError: LocalizedError {
    case refused(reason: MediaFrameAeadNegotiation.SealingDecision.RefusalReason)

    var errorDescription: String? {
        switch self {
        case .refused(let reason):
            switch reason {
            case .remoteDoesNotSupportSealing:
                return "This media lane requires per-frame encryption that the other device does not support."
            case .localDoesNotSupportSealing:
                return "This media lane requires per-frame encryption that this Mac cannot provide."
            case .sessionKeyUnavailable:
                return "This media lane requires per-frame encryption, but a media-seal session key could not be established."
            }
        }
    }
}

enum MercuryRemoteAccessAgentClientError: Error {
    case socketUnavailable
    case socketPathTooLong
    case daemonUnavailable
    case timedOut
    case writeFailed
    case readFailed
    case responseTooLarge
    case daemonRejected
}

extension String {
    var nilIfEmptyForMercury: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var canonicalMercuryPeerNodeID: String? {
        nilIfEmptyForMercury?.lowercased()
    }
}
