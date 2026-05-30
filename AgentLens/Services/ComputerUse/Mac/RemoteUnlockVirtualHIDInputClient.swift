#if canImport(AppKit) && !DISTRIBUTION_MAS
import Darwin
import Foundation
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

/// User-session client for the privileged input leaf. Prefers XPC (native audit token); falls back to
/// the legacy Unix socket adapter until migration completes.
struct RemoteUnlockVirtualHIDInputClient: Sendable {
    private static let socketPath = RemoteUnlockSetupProbe.virtualHIDBridgeSocketPath
    private static let maximumResponseBytes = 16 * 1024
    private static let requestIOTimeoutSeconds: time_t = 4
    private static let xpcClient = PrivilegedInputXPCClient()

    func dispatch(_ action: MacInputAction) async throws -> BurnBarJSONValue {
        try await Task.detached(priority: .userInitiated) {
            let request = PrivilegedInputDispatchRequest(
                operation: "input",
                kind: action.kind.rawValue,
                displayX: action.displayX,
                displayY: action.displayY,
                dragEndX: action.dragEndX,
                dragEndY: action.dragEndY,
                deltaX: action.deltaX,
                deltaY: action.deltaY,
                mouseButton: action.mouseButton,
                text: action.text,
                key: action.key,
                modifiers: action.modifiers
            )
            let envelope = PrivilegedInputDispatchEnvelope(request: request)
            if (try? Self.xpcClient.perform(envelope)) != nil {
                return Self.successPayload(for: action)
            }
            try Self.sendSocket(legacyRequest(from: request))
            return Self.successPayload(for: action)
        }.value
    }

    private static func successPayload(for action: MacInputAction) -> BurnBarJSONValue {
        .object([
            "ok": .bool(true),
            "kind": .string(action.kind.rawValue),
            "backend": .string("openburnbar_virtual_hid")
        ])
    }

    private static func legacyRequest(from request: PrivilegedInputDispatchRequest) -> RemoteUnlockVirtualHIDInputRequest {
        RemoteUnlockVirtualHIDInputRequest(
            operation: request.operation,
            password: request.password,
            kind: request.kind,
            displayX: request.displayX,
            displayY: request.displayY,
            dragEndX: request.dragEndX,
            dragEndY: request.dragEndY,
            deltaX: request.deltaX,
            deltaY: request.deltaY,
            mouseButton: request.mouseButton,
            text: request.text,
            key: request.key,
            modifiers: request.modifiers
        )
    }

    private static func sendSocket(_ request: RemoteUnlockVirtualHIDInputRequest) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Error.socketUnavailable }
        defer { close(fd) }
        configureSocket(fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try Self.socketPath.withCString { path in
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard strlen(path) < capacity else { throw Error.socketPathTooLong }
            _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    strncpy(destination, path, capacity - 1)
                }
            }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.connect(fd, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw Error.daemonUnavailable }

        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw Error.timedOut }
                    throw Error.writeFailed
                }
                written += count
            }
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var responseData = Data()
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw Error.timedOut }
                throw Error.readFailed
            }
            responseData.append(buffer, count: count)
            if responseData.count > maximumResponseBytes { throw Error.responseTooLarge }
            if responseData.last == 0x0A { break }
        }

        let response = try JSONDecoder().decode(RemoteUnlockVirtualHIDInputResponse.self, from: responseData)
        guard response.ok else { throw Error.rejected(response.error ?? "virtual_hid_bridge_rejected") }
    }

    private static func configureSocket(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        withUnsafePointer(to: &noSigPipe) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }

        var timeout = timeval(tv_sec: requestIOTimeoutSeconds, tv_usec: 0)
        let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, timeoutLength)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, timeoutLength)
        }
    }

    enum Error: Swift.Error, Equatable {
        case daemonUnavailable
        case readFailed
        case rejected(String)
        case responseTooLarge
        case socketPathTooLong
        case socketUnavailable
        case timedOut
        case writeFailed
    }
}

private struct RemoteUnlockVirtualHIDInputRequest: Encodable, Sendable {
    var operation: String
    var password: String?
    var kind: String?
    var displayX: Int?
    var displayY: Int?
    var dragEndX: Int?
    var dragEndY: Int?
    var deltaX: Int?
    var deltaY: Int?
    var mouseButton: Int?
    var text: String?
    var key: String?
    var modifiers: [String]?
}

private struct RemoteUnlockVirtualHIDInputResponse: Decodable, Sendable {
    var ok: Bool
    var error: String?
}
#endif
