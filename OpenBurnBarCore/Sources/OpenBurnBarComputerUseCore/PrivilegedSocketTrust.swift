import Darwin
import Foundation
#if os(macOS)
import Security
#endif

/// Failures raised by shared privileged-socket trust primitives.
public enum PrivilegedSocketTrustError: Error, LocalizedError, Equatable, Sendable {
    case auditTokenUnavailable
    case codeSignatureInvalid(status: OSStatus)
    case serverIdentityUnavailable
    case serverNotExpectedUser(expected: uid_t, actual: uid_t)

    public var errorDescription: String? {
        switch self {
        case .auditTokenUnavailable:
            return "OpenBurnBar could not read the peer audit token for the local privileged socket."
        case .codeSignatureInvalid(let status):
            return "OpenBurnBar code-signature validation failed with OSStatus \(status). The peer must be signed by the OpenBurnBar team with an allowed identifier, hardened runtime, and library validation."
        case .serverIdentityUnavailable:
            return "OpenBurnBar could not verify the owner of the local privileged socket peer."
        case .serverNotExpectedUser(let expected, let actual):
            return "OpenBurnBar rejected the local privileged socket peer because it is owned by user \(actual), not the expected user \(expected)."
        }
    }
}

/// Canonical OpenBurnBar signing identity and UNIX-socket peer-trust primitives.
///
/// Single source of truth for every privileged-socket trust decision: the
/// execution leaf authenticating clients, the bridge authenticating console
/// peers, and — critically — clients authenticating the *server* before
/// writing a credential-bearing envelope. Both halves of every privileged
/// connection validate the other side with the same requirement.
///
/// Keep `teamID` in sync with `DEVELOPMENT_TEAM` in `project.yml` /
/// `OpenBurnBar.xcodeproj`.
public enum OpenBurnBarPrivilegedTrust: Sendable {
    /// Ten-character Apple Developer Team ID (Organizational Unit on the leaf certificate).
    public static let teamID = "4Y367DF25B"

    /// Bundle identifier prefix for first-party OpenBurnBar binaries (`com.openburnbar.*`).
    public static let bundleIdentifierPrefix = "com.openburnbar"

    /// Exact bundle identifiers of first-party binaries permitted to call the
    /// main daemon JSON-RPC socket. This is intentionally wider than
    /// ``privilegedInputPeerBundleIdentifiers`` because the signed CLI is a
    /// supported health/support client for daemon RPCs, but it must not be a
    /// peer on credential-bearing input sockets.
    public static let daemonRPCPeerBundleIdentifiers: [String] = [
        "com.openburnbar.app",
        "com.openburnbar.daemon",
        "com.openburnbar.cli"
    ]

    /// Exact bundle identifier of the root remote-access LaunchDaemon behind
    /// `/var/run/openburnbar-remote-access-agent.sock`. Clients MUST
    /// authenticate the agent server against this identifier specifically
    /// (``remoteAccessAgentDesignatedRequirement``), not against the shared
    /// ``privilegedInputPeerBundleIdentifiers`` allowlist: the socket path
    /// carries the macOS login password, and any first-party root helper
    /// listening there (daemon, input helper, HID bridge) would otherwise
    /// pass the shared-allowlist requirement and receive the credential.
    public static let remoteAccessAgentIdentifier = "com.openburnbar.remote-access-agent"

    /// Exact bundle identifiers of first-party binaries permitted on privileged
    /// input/control sockets. These sockets can carry local-auth credentials or
    /// synthesize user input, so helper trust is narrower than daemon RPC trust
    /// and excludes the general-purpose CLI.
    ///
    /// Security remediation M-9: the Code Signing Requirement Language `identifier`
    /// operator is **exact-match only** — `identifier "com.openburnbar.*"` matches a
    /// binary whose identifier is the literal string `com.openburnbar.*` (with an
    /// asterisk), which no binary has, so a prefix-style requirement actually REJECTED
    /// the real first-party daemon/app (verified: `codesign -v -R='identifier
    /// "com.openburnbar.*"'` fails to satisfy for `com.openburnbar.daemon`). There is
    /// no identifier-prefix operator in the language, so we enumerate the exact
    /// privileged peers and OR them together. The Team-ID + hardened-runtime +
    /// library-validation clauses remain the primary first-party gate.
    ///
    /// The remote-access agent (`com.openburnbar.remote-access-agent`) is
    /// deliberately NOT in this shared allowlist (Cursor security review,
    /// round 2): listing it here would let a uid-0 process signed as the agent
    /// satisfy the default peer requirement on sibling privileged-input / HID /
    /// kill-switch lanes where it has no business, contradicting its
    /// HID/keychain isolation. Clients authenticate the agent SERVER through
    /// the exact-identifier ``remoteAccessAgentDesignatedRequirement`` instead,
    /// and the agent does not act as a client on those other lanes.
    public static let privilegedInputPeerBundleIdentifiers: [String] = [
        "com.openburnbar.app",
        "com.openburnbar.daemon",
        "com.openburnbar.privileged-input-execution",
        "com.openburnbar.virtual-hid-bridge"
    ]

    /// Backwards-compatible name for the strict privileged-input profile.
    public static let privilegedPeerBundleIdentifiers = privilegedInputPeerBundleIdentifiers

    /// Build an `(identifier "a" or identifier "b" ...)` sub-clause from an
    /// exact identifier allowlist.
    public static func identifierClause(for bundleIdentifiers: [String]) -> String {
        let terms = bundleIdentifiers.map { "identifier \"\($0)\"" }
        return "(\(terms.joined(separator: " or ")))"
    }

    /// The `(identifier "a" or identifier "b" ...)` sub-clause built from
    /// ``privilegedPeerBundleIdentifiers``.
    public static var privilegedPeerIdentifierClause: String {
        identifierClause(for: privilegedPeerBundleIdentifiers)
    }

    /// The `(identifier "a" or identifier "b" ...)` sub-clause built from
    /// ``daemonRPCPeerBundleIdentifiers``.
    public static var daemonRPCPeerIdentifierClause: String {
        identifierClause(for: daemonRPCPeerBundleIdentifiers)
    }

    /// The `(identifier "a" or identifier "b" ...)` sub-clause built from
    /// ``privilegedInputPeerBundleIdentifiers``.
    public static var privilegedInputPeerIdentifierClause: String {
        identifierClause(for: privilegedInputPeerBundleIdentifiers)
    }

    /// Designated requirement string passed to `SecRequirementCreateWithString` for peer validation.
    ///
    /// Requires an Apple-anchored Developer-ID / Apple Development signature, the
    /// OpenBurnBar Team ID on the leaf certificate, and one of the exact first-party
    /// privileged-input peer bundle identifiers.
    ///
    /// Security remediation M-9: hardened-runtime and library-validation are
    /// CodeDirectory flags that the requirement language cannot express
    /// (`(info[ApplicationFlags] & ...)` is rejected with `errSecCSReqInvalid`,
    /// verified), so they are enforced PROGRAMMATICALLY in
    /// ``validateCodeSignature(ofAuditToken:)`` via `SecCodeCopySigningInformation`.
    public static let privilegedInputPeerDesignatedRequirement: String = """
    anchor apple generic and certificate leaf[subject.OU] = "\(teamID)" and \(privilegedInputPeerIdentifierClause)
    """

    /// Designated requirement for main-daemon JSON-RPC clients. This includes
    /// the signed CLI, whose authority is still bounded by the daemon bearer
    /// token and RPC-level authorization.
    public static let daemonRPCPeerDesignatedRequirement: String = """
    anchor apple generic and certificate leaf[subject.OU] = "\(teamID)" and \(daemonRPCPeerIdentifierClause)
    """

    /// Designated requirement the remote-access-agent SERVER must satisfy when
    /// a client authenticates it over `/var/run/openburnbar-remote-access-agent.sock`.
    /// Pinned to the agent's exact identifier rather than the shared
    /// privileged-input allowlist: the socket carries the macOS login password,
    /// so any first-party root helper squatting the path must NOT pass. Only
    /// the agent itself may receive credentials typed through this lane.
    public static let remoteAccessAgentDesignatedRequirement: String = """
    anchor apple generic and certificate leaf[subject.OU] = "\(teamID)" and identifier "\(remoteAccessAgentIdentifier)"
    """

    /// Backwards-compatible default: the strict privileged-input profile.
    public static let privilegedPeerDesignatedRequirement = privilegedInputPeerDesignatedRequirement

    /// CodeDirectory signature flag for the hardened runtime (`kSecCodeSignatureRuntime`).
    public static let hardenedRuntimeFlag: UInt32 = 0x1_0000
    /// CodeDirectory signature flag for library validation (`kSecCodeSignatureLibraryValidation`).
    public static let libraryValidationFlag: UInt32 = 0x2000

    /// `SOL_LOCAL` / `LOCAL_PEERTOKEN` — peer audit token of the other end of a
    /// connected UNIX-domain socket.
    ///
    /// The SDK does not export this constant to Swift; the value is pinned to
    /// `<sys/un.h>` `LOCAL_PEERTOKEN (0x006)`. A previous hand-copied value
    /// (0x102) silently broke every peer-auth call (fail-closed, lane dead) and
    /// survived review because nothing exercised a live socket —
    /// `PrivilegedSocketTrustTests.test_peerAuditToken_readsTokenOnLiveSocketPair`
    /// now pins this against a real `getsockopt` so it cannot regress.
    public static let localPeerTokenOption: Int32 = 0x006

    /// Read the peer's audit token from a connected UNIX-domain socket.
    /// Works symmetrically: servers read accepted clients, clients read the server.
    public static func peerAuditToken(socketFD: Int32) throws -> audit_token_t {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let status = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(socketFD, SOL_LOCAL, localPeerTokenOption, pointer, &length)
        }
        guard status == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else {
            throw PrivilegedSocketTrustError.auditTokenUnavailable
        }
        return token
    }

    /// Read the peer's audit token as raw bytes (for forwarding inside an envelope).
    public static func peerAuditTokenData(socketFD: Int32) throws -> Data {
        var token = try peerAuditToken(socketFD: socketFD)
        return Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
    }

#if os(macOS)
    /// Validate that the process behind `auditToken` carries a valid first-party
    /// code signature: Apple anchor + Team ID + exact privileged identifier,
    /// plus hardened-runtime and library-validation CodeDirectory flags.
    @discardableResult
    public static func validateCodeSignature(
        ofAuditToken auditToken: audit_token_t,
        requirementString: String = privilegedPeerDesignatedRequirement
    ) throws -> String {
        var code: SecCode?
        var token = auditToken
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes: [String: Any] = [kSecGuestAttributeAudit as String: tokenData]
        let status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code)
        guard status == errSecSuccess, let code else {
            throw PrivilegedSocketTrustError.codeSignatureInvalid(status: status)
        }
        return try validateCodeSignature(code, requirementString: requirementString)
    }

    /// Validate a helper binary on disk before installing or launching it.
    /// This closes the gap where launchd would execute a user-writable swapped
    /// helper path even though live socket peers were signature-checked later.
    public static func validateStaticCode(at url: URL) throws {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw PrivilegedSocketTrustError.codeSignatureInvalid(status: status)
        }
        try validateStaticCode(staticCode)
    }

    /// `requirementString` is injectable for tests only (the default is the
    /// production designated requirement): unit tests cannot mint a process
    /// signed with the first-party identity, so they exercise the
    /// static-code/flag plumbing against the Apple-signed test host instead.
    @discardableResult
    static func validateCodeSignature(
        _ code: SecCode,
        requirementString: String = privilegedPeerDesignatedRequirement
    ) throws -> String {
        let requirement = try codeRequirement(requirementString)

        // This path authenticates a process that is already running and bound to
        // the accepted socket's kernel-issued audit token. Use the dynamic-code
        // validator so each short-lived daemon RPC verifies the live executable
        // without recursively hashing the app bundle's resources again.
        //
        // On-disk install/launch validation intentionally remains on
        // `SecStaticCodeCheckValidity` below because it must detect resource and
        // bundle mutation before execution.
        let validity = SecCodeCheckValidity(code, [], requirement)
        guard validity == errSecSuccess else {
            throw PrivilegedSocketTrustError.codeSignatureInvalid(status: validity)
        }

        // Signing-information extraction is imported as a static-code API in
        // Swift. Converting the already-validated live code here does not run
        // the expensive static validity check again.
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            throw PrivilegedSocketTrustError.codeSignatureInvalid(status: staticStatus)
        }

        return try validatedIdentifierAndFlags(from: staticCode)
    }

    /// `requirementString` is injectable for tests only; production callers use
    /// ``privilegedPeerDesignatedRequirement``.
    @discardableResult
    static func validateStaticCode(
        _ staticCode: SecStaticCode,
        requirementString: String = privilegedPeerDesignatedRequirement
    ) throws -> String {
        let requirement = try codeRequirement(requirementString)

        let validity = SecStaticCodeCheckValidity(staticCode, [], requirement)
        guard validity == errSecSuccess else {
            throw PrivilegedSocketTrustError.codeSignatureInvalid(status: validity)
        }

        return try validatedIdentifierAndFlags(from: staticCode)
    }

    private static func codeRequirement(_ requirementString: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString(
            requirementString as CFString,
            [],
            &requirement
        )
        guard requirementStatus == errSecSuccess, let requirement else {
            throw PrivilegedSocketTrustError.codeSignatureInvalid(status: requirementStatus)
        }
        return requirement
    }

    private static func validatedIdentifierAndFlags(from code: SecStaticCode) throws -> String {
        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: 0), &infoCF)
        guard infoStatus == errSecSuccess,
              let info = infoCF as? [String: Any],
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let flags = info[kSecCodeInfoFlags as String] as? UInt32 else {
            throw PrivilegedSocketTrustError.codeSignatureInvalid(status: infoStatus)
        }
        try validateCodeDirectoryFlags(flags)
        return identifier
    }

    /// M-9 policy core, separated from the SecCode plumbing so the bit logic
    /// is directly unit-testable: both hardened runtime and library
    /// validation must be set on the peer's CodeDirectory.
    static func validateCodeDirectoryFlags(_ flags: UInt32) throws {
        let hasHardenedRuntime = (flags & hardenedRuntimeFlag) != 0
        let hasLibraryValidation = (flags & libraryValidationFlag) != 0
        guard hasHardenedRuntime, hasLibraryValidation else {
            // errSecCSReqFailed: signature is valid but does not meet our policy
            // (missing hardened runtime and/or library validation).
            throw PrivilegedSocketTrustError.codeSignatureInvalid(status: errSecCSReqFailed)
        }
    }
#endif

    /// Authenticate the SERVER side of a freshly connected privileged socket
    /// before any payload is written.
    ///
    /// The execution leaf carries the macOS login password for `typeCredential`,
    /// so a client that skips this check would hand the credential to whatever
    /// process is listening at the path. Server identity is established the same
    /// way the server authenticates clients: peer UID must match the expected
    /// owner, and the peer process must satisfy the first-party designated
    /// requirement (injectable for tests).
    public static func validateServerPeer(
        socketFD: Int32,
        expectedUID: uid_t,
        codeSignatureValidator: (audit_token_t) throws -> Void
    ) throws {
        var serverUID: uid_t = 0
        var serverGID: gid_t = 0
        guard getpeereid(socketFD, &serverUID, &serverGID) == 0 else {
            throw PrivilegedSocketTrustError.serverIdentityUnavailable
        }
        guard serverUID == expectedUID else {
            throw PrivilegedSocketTrustError.serverNotExpectedUser(expected: expectedUID, actual: serverUID)
        }
        let token = try peerAuditToken(socketFD: socketFD)
        try codeSignatureValidator(token)
    }
}
