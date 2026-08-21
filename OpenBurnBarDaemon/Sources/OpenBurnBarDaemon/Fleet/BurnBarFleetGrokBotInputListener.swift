import Foundation
import OpenBurnBarKernel
#if canImport(Darwin)
import Darwin
#endif
#if os(Linux)
import Glibc
#endif

/// Authenticated grok-bot input. Loopback without a peer credential or 0600 token is rejected.
public struct BurnBarFleetGrokBotInputListener: Sendable {
    public enum Auth: Equatable, Sendable {
        case peerCredential(expectedPid: Int32)
        case tokenFile(url: URL)
        case none
    }

    public enum Error: Swift.Error, Equatable {
        case unauthenticatedLoopback
        case fenceDenied
    }

    public var auth: Auth
    public var fenceAllows: @Sendable () -> Bool
    public var evaluate: @Sendable (String) -> Bool

    public init(
        auth: Auth,
        fenceAllows: @escaping @Sendable () -> Bool = { true },
        evaluate: @escaping @Sendable (String) -> Bool = { _ in false }
    ) {
        self.auth = auth
        self.fenceAllows = fenceAllows
        self.evaluate = evaluate
    }

    public func accept(
        input: String,
        remoteAddress: String,
        peerUid: uid_t? = nil,
        peerPid: pid_t? = nil,
        presentedToken: Data? = nil
    ) throws -> String {
        guard Self.isLoopback(remoteAddress) else {
            throw Error.unauthenticatedLoopback
        }
        switch auth {
        case .none:
            throw Error.unauthenticatedLoopback
        case .peerCredential(let expectedPid):
            guard let peerUid, peerUid == getuid() else {
                throw Error.unauthenticatedLoopback
            }
            if expectedPid != 0 {
                guard let peerPid, peerPid == expectedPid else {
                    throw Error.unauthenticatedLoopback
                }
            }
        case .tokenFile(let url):
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let posix = attrs[.posixPermissions] as? NSNumber
            guard posix?.intValue == 0o600 else { throw Error.unauthenticatedLoopback }
            let expected = try Data(contentsOf: url)
            guard let presentedToken, Self.timingSafeEqual(expected, presentedToken) else {
                throw Error.unauthenticatedLoopback
            }
        }
        guard fenceAllows() else { throw Error.fenceDenied }
        guard evaluate(input) else { throw Error.fenceDenied }
        return input
    }

    public static func isLoopback(_ remoteAddress: String) -> Bool {
        let trimmed = remoteAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "127.0.0.1" || trimmed == "::1" || trimmed == "[::1]" {
            return true
        }
        if trimmed.hasPrefix("127.0.0.1:") { return true }
        if trimmed.hasPrefix("[::1]:") { return true }
        return false
    }

    /// Bind a loopback TCP listener. Callers must still `accept()` each
    /// connection through the peer-credential / token policy.
    public static func bindLoopback(port: UInt16 = 0) throws -> (fd: Int32, port: UInt16) {
        // Glibc types the SOCK_* constants as `__socket_type`; Darwin types them as
        // the `Int32` that `socket(_:_:_:)` wants. Same idiom as
        // `BurnBarUnixDomainSocket` and `HermesGatewayProbe`.
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw Error.unauthenticatedLoopback }
        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        #if os(Linux)
        addr.sin_family = sa_family_t(AF_INET)
        #else
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        #endif
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 4) == 0 else {
            close(fd)
            throw Error.unauthenticatedLoopback
        }
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard got == 0 else {
            close(fd)
            throw Error.unauthenticatedLoopback
        }
        return (fd, UInt16(bigEndian: actual.sin_port))
    }

    /// Linux `SO_PEERCRED` / Darwin `LOCAL_PEERPID`.
    public static func peerCredentials(socketFD: Int32) -> (uid: uid_t, pid: pid_t)? {
        #if os(Linux)
        var cred = (pid: pid_t(0), uid: uid_t(0), gid: gid_t(0))
        var len = socklen_t(MemoryLayout.size(ofValue: cred))
        let soPeerCred: Int32 = 17
        guard getsockopt(socketFD, SOL_SOCKET, soPeerCred, &cred, &len) == 0 else { return nil }
        return (cred.uid, cred.pid)
        #else
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let localPeerPid: Int32 = 0x002
        guard getsockopt(socketFD, SOL_LOCAL, localPeerPid, &pid, &len) == 0 else { return nil }
        return (getuid(), pid)
        #endif
    }

    static func timingSafeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }
}
