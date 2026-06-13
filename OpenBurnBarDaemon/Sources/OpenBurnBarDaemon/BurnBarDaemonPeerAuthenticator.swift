import OpenBurnBarComputerUseCore
import Darwin
import Foundation

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
    case codeSignatureInvalid(status: OSStatus)
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
    public typealias CodeSignatureValidator = @Sendable (audit_token_t) throws -> Void

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

    /// Validate the accepted client socket. When enforcement is off this is a
    /// no-op. When on, the peer's audit token must satisfy the first-party
    /// designated requirement; any failure (token unreadable, signature invalid,
    /// or unavailable) is fail-closed and logged.
    public func validatePeer(socketFD: Int32, peerPID: pid_t?) throws {
        guard isEnforced else { return }

        let auditToken: audit_token_t
        do {
            auditToken = try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: socketFD)
        } catch {
            reject(.auditTokenUnavailable, peerPID: peerPID)
            throw BurnBarDaemonPeerAuthenticationFailure.auditTokenUnavailable
        }

        do {
            try validateCodeSignature(auditToken)
        } catch let failure as BurnBarDaemonPeerAuthenticationFailure {
            reject(failure, peerPID: peerPID)
            throw failure
        } catch PrivilegedSocketTrustError.codeSignatureInvalid(let status) {
            let wrapped = BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: status)
            reject(wrapped, peerPID: peerPID)
            throw wrapped
        } catch {
            let wrapped = BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: errSecCSReqFailed)
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
    public static func defaultCodeSignatureValidation(auditToken: audit_token_t) throws {
        #if os(macOS)
        do {
            try OpenBurnBarPrivilegedTrust.validateCodeSignature(ofAuditToken: auditToken)
        } catch PrivilegedSocketTrustError.codeSignatureInvalid(let status) {
            throw BurnBarDaemonPeerAuthenticationFailure.codeSignatureInvalid(status: status)
        }
        #else
        _ = auditToken
        #endif
    }
}
