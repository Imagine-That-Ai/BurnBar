import Darwin
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarRemoteAccessAgentCore

private let maximumRequestBytes = 16 * 1024
private let requestIOTimeoutSeconds: time_t = 4
private let localPeerTokenOption: Int32 = 0x006

private func executionLog(_ message: String) {
    let line = "privileged_input_execution \(Date().timeIntervalSince1970): \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    FileHandle.standardOutput.write(data)
}

@main
struct OpenBurnBarPrivilegedInputExecutionMain {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        do {
            let keyboard = try VirtualHIDKeyboardEngine()
            let handler = PrivilegedInputDispatchHandler(
                auditSocketLabel: PrivilegedInputXPCConstants.userSessionSocketPath(),
                keyboard: keyboard
            )
            let socketPath = argumentValue("--socket") ?? PrivilegedInputXPCConstants.userSessionSocketPath()
            let server = try PrivilegedInputExecutionSocketServer(socketPath: socketPath, handler: handler)
            executionLog("listening socket=\(socketPath)")
            try server.run()
        } catch {
            executionLog("fatal detail=\(String(describing: error))")
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

private final class PrivilegedInputExecutionSocketServer {
    private let socketPath: String
    private let socketFD: Int32
    private let handler: PrivilegedInputDispatchHandler
    private let peerAuthenticator: PrivilegedPeerAuthenticator

    init(socketPath: String, handler: PrivilegedInputDispatchHandler) throws {
        self.socketPath = socketPath
        self.handler = handler
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
            guard strlen(path) < capacity else { throw POSIXError(.ENAMETOOLONG) }
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
        _ = chmod(socketPath, S_IRUSR | S_IWUSR)

        guard listen(socketFD, SOMAXCONN) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
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
            try validateSocketPeer(client)
            let envelope = try JSONDecoder().decode(
                PrivilegedInputDispatchEnvelope.self,
                from: try readRequest(from: client)
            )
            let response = try handler.handle(envelope: envelope)
            try write(response, to: client)
        } catch {
            let response = PrivilegedInputDispatchResponse(
                ok: false,
                error: (error as? VirtualHIDKeyboardEngine.EngineError)?.rawValue ?? "request_failed"
            )
            executionLog("request failed detail=\(String(describing: error))")
            try? write(response, to: client)
        }
    }

    private func validateSocketPeer(_ client: Int32) throws {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0 else {
            throw PrivilegedPeerAuthenticationFailure.peerIdentityUnavailable
        }
        if peerUID == 0 {
            var token = audit_token_t()
            var length = socklen_t(MemoryLayout<audit_token_t>.size)
            let status = withUnsafeMutablePointer(to: &token) { pointer in
                getsockopt(client, SOL_LOCAL, localPeerTokenOption, pointer, &length)
            }
            guard status == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else {
                throw PrivilegedPeerAuthenticationFailure.auditTokenUnavailable
            }
            try PrivilegedPeerAuthenticator.defaultCodeSignatureValidation(auditToken: token)
            PrivilegedSocketAudit.record(
                PrivilegedSocketAuditRecord(event: .peerAccepted, socket: socketPath, peerUID: 0)
            )
            return
        }

        try peerAuthenticator.validateUnixSocketPeer(
            socketFD: client,
            consoleUser: RemoteAccessConsoleUser(uid: getuid(), gid: getgid())
        )
    }

    private func readRequest(from client: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw POSIXError(.ETIMEDOUT) }
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            data.append(buffer, count: count)
            if data.count > maximumRequestBytes { throw POSIXError(.EMSGSIZE) }
            if data.last == 0x0A { break }
        }
        guard !data.isEmpty else { throw POSIXError(.ENODATA) }
        return data
    }

    private func write(_ response: PrivilegedInputDispatchResponse, to client: Int32) throws {
        var data = try JSONEncoder().encode(response)
        data.append(0x0A)
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
