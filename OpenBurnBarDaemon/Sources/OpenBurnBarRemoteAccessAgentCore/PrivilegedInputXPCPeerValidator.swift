import Foundation
import Security

/// Validates XPC peers (or forwarded audit tokens) for the privileged input-execution leaf.
public enum PrivilegedInputXPCPeerValidator: Sendable {
    public static func validateConnection(_ connection: NSXPCConnection) throws {
        guard let token = connection.openBurnBarPeerAuditToken else {
            throw PrivilegedPeerAuthenticationFailure.auditTokenUnavailable
        }
        try PrivilegedPeerAuthenticator.defaultCodeSignatureValidation(auditToken: token)
    }

    public static func validateForwardedAuditToken(_ data: Data) throws {
        guard data.count == MemoryLayout<audit_token_t>.size else {
            throw PrivilegedPeerAuthenticationFailure.auditTokenUnavailable
        }
        var token = audit_token_t()
        _ = data.withUnsafeBytes { raw in
            memcpy(&token, raw.baseAddress!, MemoryLayout<audit_token_t>.size)
        }
        try PrivilegedPeerAuthenticator.defaultCodeSignatureValidation(auditToken: token)
    }
}

private extension NSXPCConnection {
    /// Private `auditToken` KVC — Developer-ID privileged helper only (not MAS).
    var openBurnBarPeerAuditToken: audit_token_t? {
        guard responds(to: Selector(("auditToken"))),
              let value = value(forKey: "auditToken") as? NSValue else {
            return nil
        }
        var token = audit_token_t()
        value.getValue(&token)
        return token
    }
}
