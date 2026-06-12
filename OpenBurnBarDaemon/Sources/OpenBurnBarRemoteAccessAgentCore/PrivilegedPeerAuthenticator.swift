import Darwin
import Foundation
import OpenBurnBarComputerUseCore
import Security

public enum PrivilegedPeerAuthenticationFailure: Error, Equatable, Sendable {
    case peerIdentityUnavailable
    case consoleUserUnavailable
    case peerNotConsoleUser
    case auditTokenUnavailable
    case codeSignatureInvalid(status: OSStatus)
}

/// Validates UNIX socket peers for privileged OpenBurnBar daemons.
///
/// Cheap gate: peer UID must match the interactive console user. Authority: peer process must carry
/// a valid first-party code signature for `com.openburnbar.*` under the canonical Team ID with
/// hardened runtime and library validation enabled. The trust primitives are shared with socket
/// clients via `OpenBurnBarPrivilegedTrust` (`OpenBurnBarComputerUseCore`).
public struct PrivilegedPeerAuthenticator: Sendable {
    public typealias CodeSignatureValidator = @Sendable (audit_token_t) throws -> Void

    public let socketLabel: String
    private let validateCodeSignature: CodeSignatureValidator

    public init(
        socketLabel: String,
        validateCodeSignature: @escaping @Sendable CodeSignatureValidator = PrivilegedPeerAuthenticator.defaultCodeSignatureValidation
    ) {
        self.socketLabel = socketLabel
        self.validateCodeSignature = validateCodeSignature
    }

    /// Validate the accepted client socket. Throws `PrivilegedPeerAuthenticationFailure` and emits
    /// `privileged_socket_peer_rejected` on failure.
    public func validateUnixSocketPeer(
        socketFD: Int32,
        consoleUser: RemoteAccessConsoleUser?
    ) throws {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(socketFD, &peerUID, &peerGID) == 0 else {
            reject(detail: PrivilegedPeerAuthenticationFailure.peerIdentityUnavailable)
            throw PrivilegedPeerAuthenticationFailure.peerIdentityUnavailable
        }
        guard let consoleUser else {
            reject(detail: PrivilegedPeerAuthenticationFailure.consoleUserUnavailable, peerUID: peerUID)
            throw PrivilegedPeerAuthenticationFailure.consoleUserUnavailable
        }
        guard peerUID == consoleUser.uid else {
            reject(detail: PrivilegedPeerAuthenticationFailure.peerNotConsoleUser, peerUID: peerUID)
            throw PrivilegedPeerAuthenticationFailure.peerNotConsoleUser
        }

        let auditToken: audit_token_t
        do {
            auditToken = try OpenBurnBarPrivilegedTrust.peerAuditToken(socketFD: socketFD)
        } catch {
            reject(detail: PrivilegedPeerAuthenticationFailure.auditTokenUnavailable, peerUID: peerUID)
            throw PrivilegedPeerAuthenticationFailure.auditTokenUnavailable
        }
        do {
            try validateCodeSignature(auditToken)
        } catch let failure as PrivilegedPeerAuthenticationFailure {
            reject(detail: failure, peerUID: peerUID)
            throw failure
        } catch PrivilegedSocketTrustError.codeSignatureInvalid(let status) {
            let wrapped = PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: status)
            reject(detail: wrapped, peerUID: peerUID)
            throw wrapped
        } catch {
            let wrapped = PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: errSecCSReqFailed)
            reject(detail: wrapped, peerUID: peerUID)
            throw wrapped
        }

        PrivilegedSocketAudit.record(
            PrivilegedSocketAuditRecord(
                event: .peerAccepted,
                socket: socketLabel,
                peerUID: peerUID
            )
        )
    }

    private func reject(
        detail: PrivilegedPeerAuthenticationFailure,
        peerUID: uid_t? = nil
    ) {
        PrivilegedSocketAudit.record(
            PrivilegedSocketAuditRecord(
                event: .peerRejected,
                socket: socketLabel,
                detail: String(describing: detail),
                peerUID: peerUID.map { UInt32($0) }
            )
        )
    }

    public static func defaultCodeSignatureValidation(auditToken: audit_token_t) throws {
        do {
            try OpenBurnBarPrivilegedTrust.validateCodeSignature(ofAuditToken: auditToken)
        } catch PrivilegedSocketTrustError.codeSignatureInvalid(let status) {
            throw PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: status)
        }
    }
}
