import Darwin
import Foundation
import Security

/// `SOL_LOCAL` / `LOCAL_PEERTOKEN` — peer audit token at UNIX socket accept time.
private let localPeerTokenOption: Int32 = 0x102

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
/// hardened runtime and library validation enabled.
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

        let auditToken = try readPeerAuditToken(socketFD: socketFD)
        do {
            try validateCodeSignature(auditToken)
        } catch let failure as PrivilegedPeerAuthenticationFailure {
            reject(detail: failure, peerUID: peerUID)
            throw failure
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

    private func readPeerAuditToken(socketFD: Int32) throws -> audit_token_t {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(socketFD, SOL_LOCAL, localPeerTokenOption, pointer, &length)
        }
        guard status == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else {
            throw PrivilegedPeerAuthenticationFailure.auditTokenUnavailable
        }
        return token
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
        var code: SecCode?
        var token = auditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes: [String: Any] = [kSecGuestAttributeAudit as String: tokenData]
        let status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
        guard status == errSecSuccess, let code else {
            throw PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: status)
        }

        var requirement: SecRequirement?
        let requirementString = OpenBurnBarSigningIdentity.privilegedPeerDesignatedRequirement
        let requirementStatus = SecRequirementCreateWithString(
            requirementString as CFString,
            [],
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: requirementStatus)
        }

        let validity = SecCodeCheckValidity(code, [], requirement)
        guard validity == errSecSuccess else {
            throw PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: validity)
        }

        // M-9: enforce hardened runtime + library validation PROGRAMMATICALLY.
        // These are CodeDirectory signature flags that the Code Signing
        // Requirement Language cannot express, so they cannot live in the
        // designated requirement string above (attempting it produced an
        // invalid requirement that rejected every peer). Read the running
        // peer's CodeDirectory flags and require both bits.
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: staticStatus)
        }
        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: 0), &infoCF)
        guard infoStatus == errSecSuccess,
              let info = infoCF as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? UInt32 else {
            throw PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: infoStatus)
        }
        let hasHardenedRuntime = (flags & OpenBurnBarSigningIdentity.hardenedRuntimeFlag) != 0
        let hasLibraryValidation = (flags & OpenBurnBarSigningIdentity.libraryValidationFlag) != 0
        guard hasHardenedRuntime, hasLibraryValidation else {
            // errSecCSReqFailed: signature is valid but does not meet our policy
            // (missing hardened runtime and/or library validation).
            throw PrivilegedPeerAuthenticationFailure.codeSignatureInvalid(status: errSecCSReqFailed)
        }
    }
}
