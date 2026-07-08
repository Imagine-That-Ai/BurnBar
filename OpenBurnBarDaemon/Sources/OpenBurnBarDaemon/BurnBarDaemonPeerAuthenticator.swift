import OpenBurnBarCore
import OpenBurnBarComputerUseCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

#if os(macOS)
public typealias BurnBarDaemonAuditToken = audit_token_t
public typealias BurnBarDaemonStatus = OSStatus
private let daemonTokenUnavailableStatus = errSecCSReqFailed
#elseif os(Linux)
public typealias BurnBarDaemonAuditToken = BurnBarLinuxPeerCredential
public typealias BurnBarDaemonStatus = Int32
private let daemonTokenUnavailableStatus: BurnBarDaemonStatus = -67050

struct BurnBarLinuxPeerSocketCredentials {
    var pid: pid_t = 0
    var uid: uid_t = 0
    var gid: gid_t = 0
}

public struct BurnBarLinuxPeerCredential: Equatable, Sendable {
    public let pid: pid_t
    public let uid: uid_t
    public let gid: gid_t
    public let executablePath: String
    public let executableSHA256: String

    public init(
        pid: pid_t,
        uid: uid_t,
        gid: gid_t,
        executablePath: String,
        executableSHA256: String
    ) {
        self.pid = pid
        self.uid = uid
        self.gid = gid
        self.executablePath = executablePath
        self.executableSHA256 = executableSHA256
    }
}
#else
public typealias BurnBarDaemonAuditToken = Int32
public typealias BurnBarDaemonStatus = Int32
private let daemonTokenUnavailableStatus: BurnBarDaemonStatus = -67050
#endif

/// Failures raised when authenticating a peer of the main daemon JSON-RPC socket.
///
/// RR-3: the privileged HID/input sockets already gate accepted peers by
/// audit-token code signature (`PrivilegedPeerAuthenticator`). The main daemon
/// socket carries provider-credential-bearing RPCs (run dispatch, config writes,
/// computer-use), so it must hold the same bar: a same-user process that swaps
/// the user-writable installed daemon binary (re-exec'd by launchd `KeepAlive`)
/// or simply connects to the socket must be refused before any RPC is honored.
public enum BurnBarDaemonPeerAuthenticationFailure: Error, Equatable, Sendable {
    case auditTokenUnavailable
    case codeSignatureInvalid(status: BurnBarDaemonStatus)
}

/// First-party daemon RPC peer identity after code-signature validation.
public enum BurnBarDaemonPeerIdentity: String, CaseIterable, Codable, Sendable {
    case app = "com.openburnbar.app"
    case daemon = "com.openburnbar.daemon"
    case cli = "com.openburnbar.cli"

    public var capabilityProfile: BurnBarPeerCapabilityProfile {
        switch self {
        case .app, .daemon:
            return .full
        case .cli:
            return .cliSupport
        }
    }

    public init?(bundleIdentifier: String) {
        self.init(rawValue: bundleIdentifier)
    }
}

/// Validates UNIX-socket peers of the main daemon control socket against the
/// first-party designated requirement.
///
/// Authority: the accepted peer's audit-token code signature must satisfy the
/// canonical OpenBurnBar designated requirement (Apple anchor + Team ID + exact
/// first-party identifier + hardened runtime + library validation). The trust
/// primitives are shared with the privileged sockets and socket clients via
/// `OpenBurnBarPrivilegedTrust` (`OpenBurnBarComputerUseCore`), so both halves of
/// every OpenBurnBar connection validate the other with the same requirement.
///
/// This is the load-bearing RR-3 fix: the bearer token (checked separately in
/// `BurnBarDaemonServer.responseData`) remains as defense in depth, but the
/// signature gate is what makes a swapped/forged peer binary fail closed even
/// when it learned the token.
public struct BurnBarDaemonPeerAuthenticator: Sendable {
    public typealias CodeSignatureValidator = @Sendable (BurnBarDaemonAuditToken) throws -> BurnBarDaemonPeerIdentity

    /// `true` enforces the first-party code-signature gate on every accepted
    /// peer. `false` lets every peer through — used for local in-process tests
    /// and unsigned developer builds where no binary can carry the first-party
    /// identity (mirrors how `validateDaemonBinary` defaults to a no-op on the
    /// app side). Production wires `enforced: true` in `OpenBurnBarDaemonMain`.
    public let isEnforced: Bool
    private let validateCodeSignature: CodeSignatureValidator
    private let logger: BurnBarDaemonLogger

    public init(
        enforced: Bool,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "daemon-peer-auth"),
        validateCodeSignature: @escaping CodeSignatureValidator = BurnBarDaemonPeerAuthenticator.defaultCodeSignatureValidation
    ) {
        self.isEnforced = enforced
        self.logger = logger
        self.validateCodeSignature = validateCodeSignature
    }

    /// A non-enforcing authenticator: every peer is admitted. Default for
    /// in-process tests and unsigned builds so the socket round-trip still works.
    public static let disabled = BurnBarDaemonPeerAuthenticator(enforced: false)

    /// T-DMN-05: pure, build-mode-aware decision for whether the launch
    /// environment may disable the first-party code-signature gate.
    ///
    /// The peer-codesig-disable env opt-out is a DEBUG-only convenience for
    /// unsigned developer builds. In release/distribution builds an attacker who
    /// controls the daemon's launch environment must NOT be able to strip the
    /// gate, so `resolveEnforcement` ignores the env entirely and always enforces.
    ///
    /// `isDebugBuild` is injected so the test target can prove both arms of the
    /// policy without recompiling under a different configuration. Production
    /// callers pass the real compile-time value via ``resolveEnforcementForCurrentBuild(environment:)``.
    public static func resolveEnforcement(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> Bool {
        guard isDebugBuild else {
            // Release/distribution: the env opt-out is compiled out — always enforce.
            return true
        }
        let disabled = environment["OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG"] == "1"
            || environment["BURNBAR_DAEMON_DISABLE_PEER_CODESIG"] == "1"
        return !disabled
    }

    /// Convenience that binds ``resolveEnforcement(environment:isDebugBuild:)`` to
    /// this build's compile-time `DEBUG` flag.
    public static func resolveEnforcementForCurrentBuild(environment: [String: String]) -> Bool {
        #if DEBUG
        return resolveEnforcement(environment: environment, isDebugBuild: true)
        #else
        return resolveEnforcement(environment: environment, isDebugBuild: false)
        #endif
    }

    /// Validate the accepted client socket. When enforcement is off this is a
    /// no-op returning `.full`. When on, the peer's audit token must satisfy the
    /// first-party designated requirement; any failure (token unreadable,
    /// signature invalid, or unavailable) is fail-closed and logged. The
    /// returned profile scopes the accepted peer's RPC authority.
    public func validatePeer(socketFD: Int32, peerPID: pid_t?) throws -> BurnBarPeerCapabilityProfile {
        guard isEnforced else { return .full }

        let auditToken: BurnBarDaemonAuditToken
        do {
            #if os(Linux)
            auditToken = try Self.linuxPeerCredential(socketFD: socketFD)
            #else
            auditToken = try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: socketFD)
            #endif
        } catch {
            reject(.auditTokenUnavailable, peerPID: peerPID)
            throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
        }

        do {
            let identity = try validateCodeSignature(auditToken)
            return identity.capabilityProfile
        } catch let failure as BurnBarDaemonPeerAuthenticationFailure {
            reject(failure, peerPID: peerPID)
            throw failure
        } catch {
            #if os(macOS)
            if case let PrivilegedSocketTrustError.codeSignatureInvalid(status) = error {
                let wrapped = BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(
                    status: status
                )
                reject(wrapped, peerPID: peerPID)
                throw wrapped
            }
            #endif
            let wrapped = BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(
                status: daemonTokenUnavailableStatus
            )
            reject(wrapped, peerPID: peerPID)
            throw wrapped
        }
    }

    private func reject(_ failure: BurnBarDaemonPeerAuthenticationFailure, peerPID: pid_t?) {
        logger.warning(
            "rpc_peer_code_signature_rejected",
            metadata: [
                "detail": String(describing: failure),
                "peer_pid": peerPID.map(String.init) ?? "unknown"
            ]
        )
    }

    /// Production validator: delegate to the shared first-party trust primitive
    /// and re-map its error into the daemon-peer failure space.
    @Sendable
    public static func defaultCodeSignatureValidation(auditToken: BurnBarDaemonAuditToken) throws -> BurnBarDaemonPeerIdentity {
        #if os(macOS)
        do {
            let identifier = try OpenBurnBarPrivilegedTrust.validateCodeSignature(
                ofAuditToken: auditToken,
                requirementString: OpenBurnBarPrivilegedTrust.daemonRPCPeerDesignatedRequirement
            )
            guard let identity = BurnBarDaemonPeerIdentity(bundleIdentifier: identifier) else {
                throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: errSecCSReqFailed)
            }
            return identity
        } catch PrivilegedSocketTrustError.codeSignatureInvalid(let status) {
            throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: status)
        }
        #elseif os(Linux)
        return try validateLinuxPeerCredential(auditToken)
        #else
        _ = auditToken
        throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: daemonTokenUnavailableStatus)
        #endif
    }

    #if os(Linux)
    public static func validateLinuxPeerCredential(
        _ credential: BurnBarLinuxPeerCredential,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentUID: uid_t = geteuid()
    ) throws -> BurnBarDaemonPeerIdentity {
        guard credential.uid == currentUID else {
            throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: daemonTokenUnavailableStatus)
        }

        let executablePath = URL(fileURLWithPath: credential.executablePath).standardizedFileURL.path
        let executableName = URL(fileURLWithPath: executablePath).lastPathComponent
        let identity: BurnBarDaemonPeerIdentity
        switch executableName {
        case "OpenBurnBarCLI", "openburnbar-cli", "openburnbar":
            identity = .cli
        case "OpenBurnBarDaemon", "OpenBurnBarDaemonExecutable", "openburnbar-daemon":
            identity = .daemon
        case "OpenBurnBar", "OpenBurnBarApp", "openburnbar-linux-desktop":
            identity = .app
        default:
            throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: daemonTokenUnavailableStatus)
        }

        let allowedRoots = linuxAllowedPeerRoots(environment: environment)
        let pins = linuxPeerHashPins(environment: environment)
        let expectedHash = pins[executablePath] ?? pins[credential.executablePath] ?? pins[executableName]
        guard !allowedRoots.isEmpty || expectedHash?.isEmpty == false else {
            throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: daemonTokenUnavailableStatus)
        }
        if !allowedRoots.isEmpty {
            guard allowedRoots.contains(where: { executablePath.hasPrefix($0) }) else {
                throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: daemonTokenUnavailableStatus)
            }
        }

        if let expected = expectedHash, !expected.isEmpty {
            guard constantTimeTokensEqual(credential.executableSHA256.lowercased(), expected.lowercased()) else {
                throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: daemonTokenUnavailableStatus)
            }
        }

        return identity
    }

    public static func linuxPeerCredential(socketFD: Int32) throws -> BurnBarLinuxPeerCredential {
        var credential = BurnBarLinuxPeerSocketCredentials()
        var length = socklen_t(MemoryLayout<BurnBarLinuxPeerSocketCredentials>.size)
        let status = withUnsafeMutablePointer(to: &credential) { pointer in
            getsockopt(socketFD, SOL_SOCKET, SO_PEERCRED, pointer, &length)
        }
        guard status == 0, length == socklen_t(MemoryLayout<BurnBarLinuxPeerSocketCredentials>.size) else {
            throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
        }
        let executablePath = try linuxExecutablePath(pid: credential.pid)
        let sha256 = try linuxExecutableSHA256(path: executablePath)
        return BurnBarLinuxPeerCredential(
            pid: credential.pid,
            uid: credential.uid,
            gid: credential.gid,
            executablePath: executablePath,
            executableSHA256: sha256
        )
    }

    private static func linuxExecutablePath(pid: pid_t) throws -> String {
        let linkPath = "/proc/\(pid)/exe"
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = readlink(linkPath, &buffer, buffer.count - 1)
        guard count > 0 else {
            throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
        }
        buffer[Int(count)] = 0
        return String(cString: buffer)
    }

    private static func linuxExecutableSHA256(path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return PlatformCrypto.sha256Hex(data)
    }

    private static func linuxAllowedPeerRoots(environment: [String: String]) -> [String] {
        let raw = environment["OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS"]
            ?? environment["BURNBAR_DAEMON_LINUX_PEER_ROOTS"]
        return (raw ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).standardizedFileURL.path }
            .filter { !$0.isEmpty }
    }

    private static func linuxPeerHashPins(environment: [String: String]) -> [String: String] {
        let raw = environment["OPENBURNBAR_DAEMON_LINUX_PEER_SHA256_PINS"]
            ?? environment["BURNBAR_DAEMON_LINUX_PEER_SHA256_PINS"]
            ?? ""
        var pins: [String: String] = [:]
        for entry in raw.split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            pins[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return pins
    }
    #endif
}
