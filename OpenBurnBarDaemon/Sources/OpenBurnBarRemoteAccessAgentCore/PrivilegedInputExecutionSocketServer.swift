import Darwin
import Foundation
import OpenBurnBarComputerUseCore

/// UNIX-domain socket front-end for the privileged input-execution leaf.
///
/// Listens inside a per-user 0700 directory under a root-owned parent
/// (`PrivilegedInputXPCConstants.userSessionSocketDirectory`), authenticates
/// every accepted peer (console-user UID + first-party code signature; root
/// peers — the virtual-HID bridge — by code signature alone), and dispatches
/// envelopes to the injected handler. Refuses to start if the socket
/// directory could be tampered with: this is the structural defense against
/// socket-path squatting that a world-writable location like `/tmp` cannot
/// provide.
public final class PrivilegedInputExecutionSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (PrivilegedInputDispatchEnvelope) throws -> PrivilegedInputDispatchResponse

    public enum ServerError: Error, Equatable, Sendable {
        case socketDirectoryMissing(String)
        case socketDirectoryNotOwnedByUser(String)
        case socketDirectoryPermissionsTooOpen(String)
        case socketParentDirectoryUntrusted(String)
        case socketCreateFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case socketPathTooLong
    }

    private let socketPath: String
    private let socketFD: Int32
    private let handler: Handler
    private let peerAuthenticator: PrivilegedPeerAuthenticator
    private let rootPeerCodeSignatureValidator: PrivilegedPeerAuthenticator.CodeSignatureValidator
    /// Bounds concurrent in-flight connections. Each connection costs a thread
    /// and a code-signature evaluation, so an unbounded accept loop would let a
    /// same-uid flood pile blocked threads inside a privileged helper.
    private let connectionSlots: DispatchSemaphore
    private let stateLock = NSLock()
    private var stopRequested = false

    public init(
        socketPath: String,
        requireTrustedSocketDirectory: Bool = true,
        maximumConcurrentConnections: Int = 4,
        codeSignatureValidator: @escaping PrivilegedPeerAuthenticator.CodeSignatureValidator =
            PrivilegedPeerAuthenticator.defaultCodeSignatureValidation,
        handler: @escaping Handler
    ) throws {
        self.socketPath = socketPath
        self.handler = handler
        self.peerAuthenticator = PrivilegedPeerAuthenticator(
            socketLabel: socketPath,
            validateCodeSignature: codeSignatureValidator
        )
        self.rootPeerCodeSignatureValidator = codeSignatureValidator
        self.connectionSlots = DispatchSemaphore(value: max(1, maximumConcurrentConnections))

        if requireTrustedSocketDirectory {
            try Self.validateSocketDirectory(forSocketAt: socketPath)
        }

        self.socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ServerError.socketCreateFailed(errno) }
        do {
            try bindSocket()
        } catch {
            close(socketFD)
            throw error
        }
    }

    deinit {
        close(socketFD)
        unlink(socketPath)
    }

    /// Validate that the socket's directory cannot be pre-created or swapped by
    /// another local user:
    /// - the directory itself must exist, be a real directory (not a symlink),
    ///   be owned by the current user, and be exactly 0700;
    /// - its parent must be a real directory owned by root or the current user
    ///   and not world-writable (`/tmp`'s sticky world-writable mode fails
    ///   here by construction — binding there is structurally impossible).
    public static func validateSocketDirectory(forSocketAt socketPath: String) throws {
        let directory = (socketPath as NSString).deletingLastPathComponent
        let parent = (directory as NSString).deletingLastPathComponent

        var directoryStat = stat()
        guard lstat(directory, &directoryStat) == 0 else {
            throw ServerError.socketDirectoryMissing(directory)
        }
        guard (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
            throw ServerError.socketDirectoryMissing(directory)
        }
        guard directoryStat.st_uid == getuid() else {
            throw ServerError.socketDirectoryNotOwnedByUser(directory)
        }
        guard (directoryStat.st_mode & 0o777) == 0o700 else {
            throw ServerError.socketDirectoryPermissionsTooOpen(directory)
        }

        var parentStat = stat()
        guard lstat(parent, &parentStat) == 0,
              (parentStat.st_mode & S_IFMT) == S_IFDIR,
              parentStat.st_uid == 0 || parentStat.st_uid == getuid(),
              (parentStat.st_mode & S_IWOTH) == 0 else {
            throw ServerError.socketParentDirectoryUntrusted(parent)
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRequested
    }

    /// Accept connections until `stop()` is called. Blocks the calling thread.
    public func run() {
        while !isStopped {
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
            connectionSlots.wait()
            Thread.detachNewThread { [self] in
                defer {
                    close(client)
                    connectionSlots.signal()
                }
                handle(client)
            }
        }
    }

    /// Start accepting on a background thread (test harness entry point).
    public func start() {
        Thread.detachNewThread { [self] in run() }
    }

    public func stop() {
        stateLock.lock()
        stopRequested = true
        stateLock.unlock()
    }

    private func bindSocket() throws {
        unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketPath.withCString { path in
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard strlen(path) < capacity else { throw ServerError.socketPathTooLong }
            _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                    strncpy(destination, path, capacity - 1)
                }
            }
        }

        // Clamp the umask so the socket node is never observable at default
        // permissions between bind(2) and chmod(2).
        let previousMask = umask(0o077)
        defer { _ = umask(previousMask) }

        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else { throw ServerError.bindFailed(errno) }
        _ = chmod(socketPath, S_IRUSR | S_IWUSR)

        guard listen(socketFD, SOMAXCONN) == 0 else {
            throw ServerError.listenFailed(errno)
        }
    }

    private func configureClientTimeouts(_ client: Int32) {
        var noSigPipe: Int32 = 1
        withUnsafePointer(to: &noSigPipe) { pointer in
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }

        var timeout = timeval(tv_sec: 4, tv_usec: 0)
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
            let response = try handler(envelope)
            try write(response, to: client)
        } catch {
            let response = PrivilegedInputDispatchResponse(
                ok: false,
                error: (error as? VirtualHIDKeyboardEngine.EngineError)?.rawValue ?? "request_failed"
            )
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
            // The root virtual-HID bridge forwards locked-screen input here.
            // Root has no console-user identity to compare, so the gate is the
            // first-party code signature alone.
            let token: audit_token_t
            do {
                token = try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: client)
            } catch {
                throw PrivilegedPeerAuthenticationFailure.auditTokenUnavailable
            }
            try rootPeerCodeSignatureValidator(token)
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
        let maximumRequestBytes = 16 * 1024
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
