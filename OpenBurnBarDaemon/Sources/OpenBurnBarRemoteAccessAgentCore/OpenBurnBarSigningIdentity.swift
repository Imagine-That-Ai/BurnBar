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

    /// Designated requirement string passed to `SecRequirementCreateWithString` for peer validation.
    ///
    /// Requires a Developer-ID or Apple Development signature on the connecting process, hardened
    /// runtime, library validation, and an `com.openburnbar.*` bundle identifier.
    public static let privilegedPeerDesignatedRequirement: String = """
    anchor apple generic and certificate leaf[subject.OU] = "\(teamID)" and identifier "com.openburnbar.*" and (info[ApplicationFlags] & ApplicationFlags HardenedRuntime) != 0 and (info[ApplicationFlags] & ApplicationFlags LibraryValidation) != 0
    """
}
