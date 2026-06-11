import Darwin
import Dispatch
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarRemoteAccessAgentCore
import SystemConfiguration

private let bridgeVersion = "1"
private let defaultSocketPath = "/var/run/openburnbar-virtual-hid.sock"
private let maximumRequestBytes = 16 * 1024
private let requestIOTimeoutSeconds: time_t = 2

private func bridgeLog(_ message: String) {
    let line = "virtual_hid_bridge \(Date().timeIntervalSince1970): \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    FileHandle.standardOutput.write(data)
}

@main
struct OpenBurnBarVirtualHIDBridgeMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            let socketPath = argumentValue("--socket") ?? defaultSocketPath
            let xpcClient = PrivilegedInputXPCClient()
            let server = try VirtualHIDBridgeSocketAdapter(socketPath: socketPath, xpcClient: xpcClient)
            try server.run()
        } catch {
            let detail = (error as? BridgeError)?.rawValue ?? String(describing: error)
            bridgeLog("fatal detail=\(detail)")
            exit(1)
        }
    }
}

private func argumentValue(_ name: String, in args: [String] = CommandLine.arguments) -> String? {
    guard let index = args.firstIndex(of: name),
          args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

/// Legacy Unix socket front-end: authenticates console-user peers, forwards dispatch to the HID leaf over XPC.
private final class VirtualHIDBridgeSocketAdapter {
    private let socketPath: String
    private let socketFD: Int32
    private let peerAuthenticator: PrivilegedPeerAuthenticator
    private let xpcClient: PrivilegedInputXPCClient

    init(socketPath: String, xpcClient: PrivilegedInputXPCClient) throws {
        self.socketPath = socketPath
        self.xpcClient = xpcClient
        self.peerAuthenticator = PrivilegedPeerAuthenticator(socketLabel: socketPath)
        self.socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try bindSocket()
    }

    deinit {
        close(socketFD)
        unlink(socketPath)
    }

    func run() throws -> Never {
        while true {
            refreshSocketOwner()

            var descriptor = pollfd(fd: socketFD, events: Int16(truncatingIfNeeded: POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 1_000)
            if ready < 0 {
                if errno == EINTR { continue }
                usleep(100_000)
                continue
            }
            guard ready > 0,
                  descriptor.revents & Int16(truncatingIfNeeded: POLLIN) != 0 else {
                continue
            }

            let client = accept(socketFD, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                continue
            }
            configureClientTimeouts(client)
            Thread.detachNewThread { [self] in
                handle(client)
                close(client)
            }
        }
    }

    private func bindSocket() throws {
        unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketPath.withCString { path in
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard strlen(path) < capacity else { throw BridgeError.socketPathTooLong }
            _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    strncpy(destination, path, capacity - 1)
                }
            }
        }

        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        refreshSocketOwner()

        guard listen(socketFD, SOMAXCONN) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func refreshSocketOwner() {
        let owner = resolveConsoleUser()
        _ = chown(socketPath, owner.map { uid_t($0.uid) } ?? 0, owner.map { gid_t($0.gid) } ?? 0)
        _ = chmod(socketPath, S_IRUSR | S_IWUSR)
    }

    private func configureClientTimeouts(_ client: Int32) {
        var noSigPipe: Int32 = 1
        withUnsafePointer(to: &noSigPipe) { pointer in
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }

        var timeout = timeval(tv_sec: requestIOTimeoutSeconds, tv_usec: 0)
        let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, pointer, timeoutLength)
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, pointer, timeoutLength)
        }
    }

    private func handle(_ client: Int32) {
        do {
            try peerAuthenticator.validateUnixSocketPeer(
                socketFD: client,
                consoleUser: resolveConsoleUser()
            )
            try PrivilegedInputKillSwitch.assertNotActive()
            let requestData = try readRequest(from: client)
            let legacy = try JSONDecoder().decode(LegacyBridgeRequest.self, from: requestData)
            let peerToken = try peerAuditTokenData(socketFD: client)
            let dispatchRequest = PrivilegedInputDispatchRequest(
                operation: legacy.operation,
                password: legacy.password,
                kind: legacy.kind,
                displayX: legacy.displayX,
                displayY: legacy.displayY,
                dragEndX: legacy.dragEndX,
                dragEndY: legacy.dragEndY,
                deltaX: legacy.deltaX,
                deltaY: legacy.deltaY,
                mouseButton: legacy.mouseButton,
                text: legacy.text,
                key: legacy.key,
                modifiers: legacy.modifiers
            )
            let envelope = PrivilegedInputDispatchEnvelope(
                request: dispatchRequest,
                peerAuditToken: peerToken,
                capabilityToken: legacy.capabilityToken
            )
            let response = try xpcClient.perform(envelope)
            try write(
                BridgeResponse(ok: response.ok, version: bridgeVersion, error: response.error),
                to: client
            )
        } catch {
            let detail = bridgeErrorDetail(for: error)
            bridgeLog("request failed detail=\(detail)")
            try? write(BridgeResponse(ok: false, version: bridgeVersion, error: detail), to: client)
        }
    }

    private func peerAuditTokenData(socketFD: Int32) throws -> Data {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(socketFD, SOL_LOCAL, 0x102, pointer, &length)
        }
        guard status == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else {
            throw BridgeError.peerIdentityUnavailable
        }
        return Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
    }

    private func bridgeErrorDetail(for error: Error) -> String {
        if let bridgeError = error as? BridgeError {
            return bridgeError.rawValue
        }
        if let clientError = error as? PrivilegedInputXPCClient.ClientError {
            switch clientError {
            case .connectionUnavailable, .remoteProxyUnavailable, .timedOut:
                return BridgeError.inputExecutionUnavailable.rawValue
            case .invalidResponse:
                return BridgeError.requestFailed.rawValue
            case .rejected(let detail):
                return detail
            }
        }
        if let authFailure = error as? PrivilegedPeerAuthenticationFailure {
            switch authFailure {
            case .peerIdentityUnavailable: return BridgeError.peerIdentityUnavailable.rawValue
            case .consoleUserUnavailable: return BridgeError.consoleUserUnavailable.rawValue
            case .peerNotConsoleUser: return BridgeError.peerNotConsoleUser.rawValue
            case .auditTokenUnavailable: return BridgeError.peerIdentityUnavailable.rawValue
            case .codeSignatureInvalid: return BridgeError.peerCodeSignatureInvalid.rawValue
            }
        }
        if error is PrivilegedInputKillSwitch.KillSwitchActive {
            return BridgeError.privilegedInputKillSwitchActive.rawValue
        }
        return BridgeError.requestFailed.rawValue
    }

    private func readRequest(from client: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw BridgeError.requestTimedOut }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            data.append(buffer, count: count)
            if data.count > maximumRequestBytes { throw BridgeError.requestTooLarge }
            if data.last == 0x0a { break }
        }
        guard !data.isEmpty else { throw BridgeError.emptyRequest }
        return data
    }

    private func write(_ response: BridgeResponse, to client: Int32) throws {
        var data = try JSONEncoder().encode(response)
        data.append(0x0a)
        try data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(client, base.advanced(by: written), data.count - written)
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                written += count
            }
        }
    }
}

private struct LegacyBridgeRequest: Decodable {
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
    var capabilityToken: CapabilityToken?
}

private struct BridgeResponse: Encodable {
    var ok: Bool
    var version: String
    var error: String?
}

private func resolveConsoleUser() -> RemoteAccessConsoleUser? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) else { return nil }
    return RemoteAccessConsoleUserResolver.resolve(
        dynamicStoreUser: (name: name as String, uid: uid, gid: gid),
        consoleDeviceOwner: nil
    )
}

private enum BridgeError: String, Error {
    case socketPathTooLong = "socket_path_too_long"
    case peerIdentityUnavailable = "peer_identity_unavailable"
    case consoleUserUnavailable = "console_user_unavailable"
    case peerNotConsoleUser = "peer_not_console_user"
    case peerCodeSignatureInvalid = "peer_code_signature_invalid"
    case privilegedInputKillSwitchActive = "privileged_input_kill_switch_active"
    case inputExecutionUnavailable = "privileged_input_execution_unavailable"
    case requestTimedOut = "request_timed_out"
    case requestTooLarge = "request_too_large"
    case emptyRequest = "empty_request"
    case requestFailed = "request_failed"
}
