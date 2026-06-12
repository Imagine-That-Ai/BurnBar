import Darwin
import Foundation
import os

/// XPC client for the privileged input-execution Mach service (preferred over legacy Unix socket).
public final class PrivilegedInputXPCClient: NSObject, @unchecked Sendable {
    public enum ClientError: Error, Sendable {
        case connectionUnavailable
        case remoteProxyUnavailable
        case invalidResponse
        case timedOut
        case rejected(String)
        /// The process listening at the socket path failed server authentication
        /// (wrong UID or code signature). Terminal by design: a trust failure on
        /// the socket lane means something is impersonating the helper, so we
        /// surface it loudly instead of silently downgrading to another lane.
        case serverUntrusted(String)
    }

    private static let log = Logger(subsystem: "com.openburnbar.computeruse", category: "privileged-input")

    private let machServiceName: String
    private let requestTimeout: DispatchTimeInterval
    private let socketClient: PrivilegedInputSocketClient?
    private let lock = NSLock()
    private var cachedConnections: [ConnectionMode: NSXPCConnection] = [:]

    public init(
        machServiceName: String = PrivilegedInputXPCConstants.machServiceName,
        userSessionSocketPath: String? = PrivilegedInputXPCConstants.userSessionSocketPath(),
        requestTimeout: DispatchTimeInterval = .seconds(4)
    ) {
        self.machServiceName = machServiceName
        self.requestTimeout = requestTimeout
        self.socketClient = userSessionSocketPath.map {
            PrivilegedInputSocketClient(
                socketPath: $0,
                requestTimeoutSeconds: PrivilegedInputXPCClient.timeoutSeconds(from: requestTimeout)
            )
        }
        super.init()
    }

    public func perform(_ envelope: PrivilegedInputDispatchEnvelope) throws -> PrivilegedInputDispatchResponse {
        if let socketClient {
            do {
                return try socketClient.perform(envelope)
            } catch ClientError.rejected(let detail) {
                throw ClientError.rejected(detail)
            } catch ClientError.serverUntrusted(let detail) {
                Self.log.error("privileged-input socket server failed trust validation: \(detail, privacy: .public)")
                throw ClientError.serverUntrusted(detail)
            } catch {
                // The user-session helper socket being absent is expected on
                // legacy installs; anything else is a transport fault worth a
                // diagnostic trail before we try the launchd Mach lane.
                Self.log.notice(
                    "privileged-input socket lane unavailable, falling back to Mach service: \(String(describing: error), privacy: .public)"
                )
            }
        }

        var lastConnectionError: Error?
        for mode in ConnectionMode.preferredOrder {
            do {
                return try perform(envelope, mode: mode)
            } catch ClientError.rejected(let detail) {
                throw ClientError.rejected(detail)
            } catch {
                invalidateConnection(for: mode)
                lastConnectionError = error
            }
        }
        throw lastConnectionError ?? ClientError.connectionUnavailable
    }

    private func perform(
        _ envelope: PrivilegedInputDispatchEnvelope,
        mode: ConnectionMode
    ) throws -> PrivilegedInputDispatchResponse {
        let connection = try connection(mode: mode)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let payload = try encoder.encode(envelope)

        var responseData: Data?
        var remoteError: NSError?
        let semaphore = DispatchSemaphore(value: 0)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            remoteError = error as NSError
            semaphore.signal()
        }) as? PrivilegedInputExecutionXPCProtocol else {
            throw ClientError.remoteProxyUnavailable
        }
        proxy.perform(payload) { data, error in
            responseData = data
            remoteError = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + requestTimeout) == .success else {
            throw ClientError.timedOut
        }

        if let remoteError {
            throw remoteError
        }
        guard let responseData,
              let response = try? decoder.decode(PrivilegedInputDispatchResponse.self, from: responseData) else {
            throw ClientError.invalidResponse
        }
        guard response.ok else {
            throw ClientError.rejected(response.error ?? "privileged_input_rejected")
        }
        return response
    }

    private func connection(mode: ConnectionMode) throws -> NSXPCConnection {
#if os(macOS)
        lock.lock()
        defer { lock.unlock() }

        let connection: NSXPCConnection
        if let cached = cachedConnections[mode] {
            connection = cached
        } else {
            let created = NSXPCConnection(
                machServiceName: machServiceName,
                options: mode.options
            )
            created.remoteObjectInterface = NSXPCInterface(with: PrivilegedInputExecutionXPCProtocol.self)
            created.invalidationHandler = { [weak self] in
                self?.invalidateConnection(for: mode)
            }
            created.interruptionHandler = created.invalidationHandler
            created.resume()
            cachedConnections[mode] = created
            connection = created
        }

        return connection
#else
        throw ClientError.connectionUnavailable
#endif
    }

    private func invalidateConnection(for mode: ConnectionMode) {
        lock.lock()
        let connection = cachedConnections.removeValue(forKey: mode)
        lock.unlock()
        connection?.invalidate()
    }

    private static func timeoutSeconds(from interval: DispatchTimeInterval) -> Int {
        switch interval {
        case .seconds(let value):
            return max(1, value)
        case .milliseconds(let value):
            return max(1, (value + 999) / 1_000)
        case .microseconds(let value):
            return max(1, (value + 999_999) / 1_000_000)
        case .nanoseconds(let value):
            return max(1, (value + 999_999_999) / 1_000_000_000)
        case .never:
            return 4
        @unknown default:
            return 4
        }
    }

    private enum ConnectionMode: Hashable {
        case userSession
        case privilegedSystem

        static let preferredOrder: [ConnectionMode] = [.userSession, .privilegedSystem]

        var options: NSXPCConnection.Options {
            switch self {
            case .userSession:
                return []
            case .privilegedSystem:
                return .privileged
            }
        }
    }
}

public final class PrivilegedInputSocketClient: @unchecked Sendable {
    public typealias ServerCodeSignatureValidator = @Sendable (audit_token_t) throws -> Void

    private let socketPath: String
    private let requestTimeoutSeconds: Int
    private let expectedServerUID: uid_t
    private let serverCodeSignatureValidator: ServerCodeSignatureValidator
    private let maximumResponseBytes = 16 * 1024

    /// - Parameters:
    ///   - expectedServerUID: UID the listening helper must run as. The app
    ///     talks to its own user's helper (`getuid()`); the root bridge passes
    ///     the console user's UID when forwarding.
    ///   - serverCodeSignatureValidator: injectable for tests; defaults to the
    ///     first-party designated-requirement check.
    public init(
        socketPath: String = PrivilegedInputXPCConstants.userSessionSocketPath(),
        requestTimeoutSeconds: Int = 4,
        expectedServerUID: uid_t = getuid(),
        serverCodeSignatureValidator: ServerCodeSignatureValidator? = nil
    ) {
        self.socketPath = socketPath
        self.requestTimeoutSeconds = max(1, requestTimeoutSeconds)
        self.expectedServerUID = expectedServerUID
        self.serverCodeSignatureValidator = serverCodeSignatureValidator
            ?? PrivilegedInputSocketClient.defaultServerCodeSignatureValidator
    }

    public func perform(_ envelope: PrivilegedInputDispatchEnvelope) throws -> PrivilegedInputDispatchResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PrivilegedInputXPCClient.ClientError.connectionUnavailable }
        defer { close(fd) }
        configureSocket(fd)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketPath.withCString { path in
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard strlen(path) < capacity else {
                throw PrivilegedInputXPCClient.ClientError.connectionUnavailable
            }
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
        guard connected == 0 else { throw PrivilegedInputXPCClient.ClientError.connectionUnavailable }

        // Authenticate the server BEFORE writing anything: the envelope can
        // carry the macOS login password (`typeCredential`), and a connect(2)
        // by itself proves only that *something* is listening at the path.
        do {
            try OpenBurnBarPrivilegedTrust.validateServerPeer(
                socketFD: fd,
                expectedUID: expectedServerUID,
                codeSignatureValidator: serverCodeSignatureValidator
            )
        } catch {
            throw PrivilegedInputXPCClient.ClientError.serverUntrusted(String(describing: error))
        }

        var requestData = try JSONEncoder().encode(envelope)
        requestData.append(0x0A)
        try write(requestData, to: fd)

        let responseData = try readResponse(from: fd)
        guard let response = try? JSONDecoder().decode(PrivilegedInputDispatchResponse.self, from: responseData) else {
            throw PrivilegedInputXPCClient.ClientError.invalidResponse
        }
        guard response.ok else {
            throw PrivilegedInputXPCClient.ClientError.rejected(response.error ?? "privileged_input_rejected")
        }
        return response
    }

    private static let defaultServerCodeSignatureValidator: ServerCodeSignatureValidator = { token in
#if os(macOS)
        try OpenBurnBarPrivilegedTrust.validateCodeSignature(ofAuditToken: token)
#else
        throw PrivilegedSocketTrustError.codeSignatureInvalid(status: -1)
#endif
    }

    private func configureSocket(_ fd: Int32) {
        var noSigPipe: Int32 = 1
        withUnsafePointer(to: &noSigPipe) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
        }

        var timeout = timeval(tv_sec: time_t(requestTimeoutSeconds), tv_usec: 0)
        let timeoutLength = socklen_t(MemoryLayout<timeval>.size)
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, timeoutLength)
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, timeoutLength)
        }
    }

    private func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { pointer in
            guard let base = pointer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(fd, base.advanced(by: written), data.count - written)
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw PrivilegedInputXPCClient.ClientError.timedOut
                    }
                    throw PrivilegedInputXPCClient.ClientError.connectionUnavailable
                }
                written += count
            }
        }
    }

    private func readResponse(from fd: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw PrivilegedInputXPCClient.ClientError.timedOut
                }
                throw PrivilegedInputXPCClient.ClientError.connectionUnavailable
            }
            data.append(buffer, count: count)
            if data.count > maximumResponseBytes {
                throw PrivilegedInputXPCClient.ClientError.invalidResponse
            }
            if data.last == 0x0A { break }
        }
        guard !data.isEmpty else { throw PrivilegedInputXPCClient.ClientError.invalidResponse }
        return data
    }
}
