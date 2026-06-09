import Foundation

/// Canonical OpenBurnBar Developer-ID / Apple Development signing identity used for
/// peer code-signature checks on privileged UNIX-domain sockets.
///
/// Keep in sync with `DEVELOPMENT_TEAM` in `project.yml` / `OpenBurnBar.xcodeproj`.
public enum OpenBurnBarSigningIdentity: Sendable {
    /// Ten-character Apple Developer Team ID (Organizational Unit on the leaf certificate).
    public static let teamID = "4Y367DF25B"

    /// Bundle identifier prefix for first-party OpenBurnBar binaries (`com.openburnbar.*`).
    public static let bundleIdentifierPrefix = "com.openburnbar"

    /// Exact bundle identifiers of the first-party binaries permitted to connect to
    /// a privileged socket.
    ///
    /// Security remediation M-9: the Code Signing Requirement Language `identifier`
    /// operator is **exact-match only** — `identifier "com.openburnbar.*"` matches a
    /// binary whose identifier is the literal string `com.openburnbar.*` (with an
    /// asterisk), which no binary has, so the previous requirement actually REJECTED
    /// the real first-party daemon/app (verified: `codesign -v -R='identifier
    /// "com.openburnbar.*"'` fails to satisfy for `com.openburnbar.daemon`). There is
    /// no identifier-prefix operator in the language, so we enumerate the exact
    /// privileged peers and OR them together. The Team-ID + hardened-runtime +
    /// library-validation clauses remain the primary first-party gate.
    public static let privilegedPeerBundleIdentifiers: [String] = [
        "com.openburnbar.app",
        "com.openburnbar.daemon",
        "com.openburnbar.privileged-input-execution",
        "com.openburnbar.virtual-hid-bridge",
    ]

    /// The `(identifier "a" or identifier "b" ...)` sub-clause built from
    /// ``privilegedPeerBundleIdentifiers``.
    static var privilegedPeerIdentifierClause: String {
        let terms = privilegedPeerBundleIdentifiers.map { "identifier \"\($0)\"" }
        return "(\(terms.joined(separator: " or ")))"
    }

    /// Designated requirement string passed to `SecRequirementCreateWithString` for peer validation.
    ///
    /// Requires an Apple-anchored Developer-ID / Apple Development signature, the
    /// OpenBurnBar Team ID on the leaf certificate, and one of the exact first-party
    /// privileged-peer bundle identifiers.
    ///
    /// Security remediation M-9: the previous string also contained
    /// `(info[ApplicationFlags] & ApplicationFlags HardenedRuntime) != 0 ...`. That
    /// is NOT valid Code Signing Requirement Language — `SecRequirementCreateWithString`
    /// rejects it (`errSecCSReqInvalid`, -67052, verified), which meant
    /// `defaultCodeSignatureValidation` ALWAYS threw and the privileged peer gate
    /// rejected *every* peer (fail-closed, but broken). Hardened-runtime and
    /// library-validation are CodeDirectory flags that the requirement language
    /// cannot express, so they are now enforced PROGRAMMATICALLY in
    /// `PrivilegedPeerAuthenticator.defaultCodeSignatureValidation` via
    /// `SecCodeCopySigningInformation`. This string is a valid requirement.
    public static let privilegedPeerDesignatedRequirement: String = """
    anchor apple generic and certificate leaf[subject.OU] = "\(teamID)" and \(privilegedPeerIdentifierClause)
    """

    /// CodeDirectory signature flag for the hardened runtime (`kSecCodeSignatureRuntime`).
    public static let hardenedRuntimeFlag: UInt32 = 0x1_0000
    /// CodeDirectory signature flag for library validation (`kSecCodeSignatureLibraryValidation`).
    public static let libraryValidationFlag: UInt32 = 0x2000
}
