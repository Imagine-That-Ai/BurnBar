#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

public struct BurnBarSafariDaemonRuntimePaths: Hashable, Sendable {
    public let socketURL: URL
    public let socketAuthTokenFileURL: URL

    public init(socketURL: URL, socketAuthTokenFileURL: URL) {
        self.socketURL = socketURL
        self.socketAuthTokenFileURL = socketAuthTokenFileURL
    }

    public static func live(
        fileManager: FileManager = .default,
        sharedContainerRoot: URL? = nil,
        homeDirectoryURL: URL? = nil
    ) throws -> Self {
        guard let sharedContainerRoot = sharedContainerRoot
            ?? BurnBarSafariSharedContainer.liveRoot(fileManager: fileManager) else {
            throw BurnBarSafariAppGroupPayloadError.appGroupUnavailable
        }
        return Self(
            socketURL: sharedContainerRoot.appendingPathComponent(
                "daemon.sock",
                isDirectory: false
            ),
            socketAuthTokenFileURL: sharedContainerRoot.appendingPathComponent(
                "daemon-socket-auth-token",
                isDirectory: false
            )
        )
    }

}

public enum BurnBarSafariDaemonTokenSource: String, Codable, Hashable, Sendable {
    case tokenFile
    case keychain
}

public struct BurnBarSafariDaemonAuthToken: Hashable, Sendable {
    public let value: String
    public let source: BurnBarSafariDaemonTokenSource

    public init(value: String, source: BurnBarSafariDaemonTokenSource) {
        self.value = value
        self.source = source
    }
}

public enum BurnBarSafariDaemonTokenError: Error, LocalizedError, Equatable, Sendable {
    case unavailable
    case invalidTokenFile
    case insecureTokenFile
    case keychainFailure(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "OpenBurnBar daemon authentication is unavailable."
        case .invalidTokenFile:
            return "The OpenBurnBar daemon token file is invalid."
        case .insecureTokenFile:
            return "The OpenBurnBar daemon token file failed its security checks."
        case .keychainFailure(let status):
            return "OpenBurnBar could not read daemon authentication from Keychain (OSStatus \(status))."
        }
    }
}

/// Token-file-first daemon credential resolver suitable for the sandboxed
/// Safari appex. A missing or sandbox-inaccessible runtime file falls through
/// to the shared Keychain access group; a present-but-tampered file fails
/// closed rather than silently selecting a different credential.
public struct BurnBarSafariDaemonTokenResolver: Sendable {
    public typealias TokenFileReader = @Sendable (URL) throws -> String?
    public typealias KeychainReader = @Sendable () throws -> String?

    public let tokenFileURL: URL
    private let tokenFileReader: TokenFileReader
    private let keychainReader: KeychainReader

    public init(
        tokenFileURL: URL,
        tokenFileReader: @escaping TokenFileReader,
        keychainReader: @escaping KeychainReader
    ) {
        self.tokenFileURL = tokenFileURL
        self.tokenFileReader = tokenFileReader
        self.keychainReader = keychainReader
    }

    public static func live(
        tokenFileURL: URL,
        fileManager: FileManager = .default
    ) -> Self {
        Self(
            tokenFileURL: tokenFileURL,
            tokenFileReader: { url in
                try readOwnerOnlyTokenFile(at: url, fileManager: fileManager)
            },
            keychainReader: {
                try readSharedKeychainToken()
            }
        )
    }

    public func resolve() throws -> BurnBarSafariDaemonAuthToken {
        if let fileToken = try tokenFileReader(tokenFileURL) {
            return BurnBarSafariDaemonAuthToken(value: fileToken, source: .tokenFile)
        }
        if let keychainToken = try keychainReader() {
            let trimmed = keychainToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 16 * 1024 else {
                throw BurnBarSafariDaemonTokenError.unavailable
            }
            return BurnBarSafariDaemonAuthToken(value: trimmed, source: .keychain)
        }
        throw BurnBarSafariDaemonTokenError.unavailable
    }

    static func readOwnerOnlyTokenFile(
        at url: URL,
        fileManager: FileManager
    ) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        do {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw BurnBarSafariDaemonTokenError.insecureTokenFile
            }
            guard let size = values.fileSize, size > 0, size <= 16 * 1024 else {
                throw BurnBarSafariDaemonTokenError.invalidTokenFile
            }

            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let rawPermissions = attributes[.posixPermissions] as? NSNumber else {
                throw BurnBarSafariDaemonTokenError.insecureTokenFile
            }
            let permissions = rawPermissions.intValue & 0o777
            guard permissions & ~0o600 == 0, permissions & 0o400 != 0 else {
                throw BurnBarSafariDaemonTokenError.insecureTokenFile
            }
            #if canImport(Darwin) || canImport(Glibc)
            guard let owner = attributes[.ownerAccountID] as? NSNumber,
                  owner.uint32Value == geteuid() else {
                throw BurnBarSafariDaemonTokenError.insecureTokenFile
            }
            #endif

            let token = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, token.utf8.count <= 16 * 1024 else {
                throw BurnBarSafariDaemonTokenError.invalidTokenFile
            }
            return token
        } catch let error as BurnBarSafariDaemonTokenError {
            throw error
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile || error.code == .fileReadNoPermission {
            // A sandboxed appex often cannot see the host's Application Support
            // token file. Absence/denial is expected and falls through to the
            // explicitly shared Keychain access group.
            return nil
        }
    }

    static func readSharedKeychainToken() throws -> String? {
        #if canImport(Security)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: OpenBurnBarIdentity.controllerRuntimeKeychainService,
            kSecAttrAccount as String: OpenBurnBarIdentity.daemonSocketAuthTokenAccount,
            kSecAttrAccessGroup as String: OpenBurnBarIdentity.sharedKeychainAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        #if canImport(LocalAuthentication)
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = authenticationContext
        #endif

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let token = String(data: data, encoding: .utf8) else {
                throw BurnBarSafariDaemonTokenError.keychainFailure(status: errSecDecode)
            }
            return token
        case errSecItemNotFound, errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return nil
        default:
            throw BurnBarSafariDaemonTokenError.keychainFailure(status: status)
        }
        #else
        return nil
        #endif
    }
}

public enum BurnBarSafariDaemonSocketError: Error, LocalizedError, Equatable, Sendable {
    case platformUnavailable
    case socketPathTooLong
    case requestTooLarge
    case responseTooLarge
    case emptyResponse
    case malformedResponse
    case responseIdentifierMismatch
    case protocolMismatch(expected: Int, actual: Int)
    case timedOut
    case connectionFailed(code: Int32)
    case writeFailed(code: Int32)
    case readFailed(code: Int32)
    case daemonError(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .platformUnavailable:
            return "The OpenBurnBar daemon socket is unavailable on this platform."
        case .socketPathTooLong:
            return "The OpenBurnBar daemon socket path is too long."
        case .requestTooLarge:
            return "The OpenBurnBar daemon request exceeds the safe socket envelope limit."
        case .responseTooLarge:
            return "The OpenBurnBar daemon response exceeds the safe socket response limit."
        case .emptyResponse:
            return "The OpenBurnBar daemon returned an empty response."
        case .malformedResponse:
            return "The OpenBurnBar daemon returned a malformed response."
        case .responseIdentifierMismatch:
            return "The OpenBurnBar daemon response identifier does not match its request."
        case .protocolMismatch(let expected, let actual):
            return "OpenBurnBar daemon protocol mismatch (expected \(expected), received \(actual))."
        case .timedOut:
            return "The OpenBurnBar daemon request timed out."
        case .connectionFailed(let code):
            return "OpenBurnBar daemon socket connection failed (errno \(code))."
        case .writeFailed(let code):
            return "OpenBurnBar daemon socket write failed (errno \(code))."
        case .readFailed(let code):
            return "OpenBurnBar daemon socket read failed (errno \(code))."
        case .daemonError(_, let message):
            return message
        }
    }
}

/// Narrow AF_UNIX JSON-RPC client used by the Safari native appex.
///
/// Each request uses a fresh connection, writes the complete newline-delimited
/// envelope, and reads in 64 KiB chunks until the first newline. Reads are
/// bounded independently from the daemon's smaller request ceiling so large
/// catalog/session responses do not truncate after one system call.
public struct BurnBarSafariDaemonSocketClient: Sendable {
    public let socketURL: URL
    public let tokenResolver: BurnBarSafariDaemonTokenResolver
    public let timeoutSeconds: Int
    public let maximumResponseBytes: Int

    public init(
        socketURL: URL,
        tokenResolver: BurnBarSafariDaemonTokenResolver,
        timeoutSeconds: Int = 30,
        maximumResponseBytes: Int = 16 * 1024 * 1024
    ) {
        self.socketURL = socketURL
        self.tokenResolver = tokenResolver
        self.timeoutSeconds = min(max(timeoutSeconds, 1), 30)
        self.maximumResponseBytes = min(
            max(maximumResponseBytes, 64 * 1024),
            32 * 1024 * 1024
        )
    }

    public static func live(
        fileManager: FileManager = .default,
        sharedContainerRoot: URL? = nil,
        homeDirectoryURL: URL? = nil
    ) throws -> Self {
        let paths = try BurnBarSafariDaemonRuntimePaths.live(
            fileManager: fileManager,
            sharedContainerRoot: sharedContainerRoot,
            homeDirectoryURL: homeDirectoryURL
        )
        return Self(
            socketURL: paths.socketURL,
            tokenResolver: .live(
                tokenFileURL: paths.socketAuthTokenFileURL,
                fileManager: fileManager
            )
        )
    }

    public func send(
        method: BurnBarRPCMethod,
        id: String = UUID().uuidString,
        params: BurnBarJSONValue
    ) throws -> BurnBarJSONValue {
        let token = try tokenResolver.resolve()
        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: id,
            method: method,
            authToken: token.value,
            params: params
        )
        let encoded = try JSONEncoder().encode(request)
        guard encoded.count + 1 <= BurnBarSafariBridgeWire.maximumDaemonSocketRequestBytes else {
            throw BurnBarSafariDaemonSocketError.requestTooLarge
        }
        let responseData = try sendLine(encoded)
        let envelope: BurnBarRPCResponseEnvelope<BurnBarJSONValue>
        do {
            envelope = try JSONDecoder().decode(
                BurnBarRPCResponseEnvelope<BurnBarJSONValue>.self,
                from: responseData
            )
        } catch {
            throw BurnBarSafariDaemonSocketError.malformedResponse
        }
        guard envelope.id == id else {
            throw BurnBarSafariDaemonSocketError.responseIdentifierMismatch
        }
        guard envelope.protocolVersion == BurnBarProtocolVersion.current else {
            throw BurnBarSafariDaemonSocketError.protocolMismatch(
                expected: BurnBarProtocolVersion.current,
                actual: envelope.protocolVersion
            )
        }
        if let error = envelope.error {
            throw BurnBarSafariDaemonSocketError.daemonError(
                code: error.code,
                message: error.message
            )
        }
        guard let result = envelope.result else {
            throw BurnBarSafariDaemonSocketError.emptyResponse
        }
        return result
    }

    private func sendLine(_ request: Data) throws -> Data {
        #if canImport(Darwin) || canImport(Glibc)
        #if canImport(Darwin)
        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fileDescriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fileDescriptor >= 0 else {
            throw BurnBarSafariDaemonSocketError.connectionFailed(code: errno)
        }
        defer { close(fileDescriptor) }

        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #endif
        configureTimeouts(fileDescriptor)

        var address = try socketAddress(socketURL.path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(
                    fileDescriptor,
                    rebound,
                    socklen_t(MemoryLayout<sockaddr_un>.stride)
                )
            }
        }
        guard connected == 0 else {
            let code = errno
            if isTimeout(code) { throw BurnBarSafariDaemonSocketError.timedOut }
            throw BurnBarSafariDaemonSocketError.connectionFailed(code: code)
        }

        var payload = request
        payload.append(0x0A)
        try writeAll(payload, to: fileDescriptor)
        return try readResponse(from: fileDescriptor)
        #else
        _ = request
        throw BurnBarSafariDaemonSocketError.platformUnavailable
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private func configureTimeouts(_ fileDescriptor: Int32) {
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        _ = setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        #endif
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw BurnBarSafariDaemonSocketError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }
        return address
    }

    private func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                if code == EINTR { continue }
                if isTimeout(code) { throw BurnBarSafariDaemonSocketError.timedOut }
                throw BurnBarSafariDaemonSocketError.writeFailed(code: code)
            }
        }
    }

    private func readResponse(from fileDescriptor: Int32) throws -> Data {
        var response = Data()
        response.reserveCapacity(64 * 1024)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let count = read(fileDescriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                if isTimeout(code) { throw BurnBarSafariDaemonSocketError.timedOut }
                throw BurnBarSafariDaemonSocketError.readFailed(code: code)
            }

            let bytes = buffer.prefix(count)
            if let newline = bytes.firstIndex(of: 0x0A) {
                response.append(contentsOf: bytes[..<newline])
                let trailing = bytes[bytes.index(after: newline)...]
                guard trailing.allSatisfy({ $0 == 0x0D || $0 == 0x0A || $0 == 0x20 || $0 == 0x09 }) else {
                    throw BurnBarSafariDaemonSocketError.malformedResponse
                }
                guard response.count <= maximumResponseBytes else {
                    throw BurnBarSafariDaemonSocketError.responseTooLarge
                }
                return response
            }

            guard response.count + count <= maximumResponseBytes else {
                throw BurnBarSafariDaemonSocketError.responseTooLarge
            }
            response.append(contentsOf: bytes)
        }

        while response.last == 0x0D || response.last == 0x0A {
            response.removeLast()
        }
        guard !response.isEmpty else {
            throw BurnBarSafariDaemonSocketError.emptyResponse
        }
        return response
    }

    private func isTimeout(_ code: Int32) -> Bool {
        code == ETIMEDOUT || code == EAGAIN || code == EWOULDBLOCK
    }
    #endif
}
