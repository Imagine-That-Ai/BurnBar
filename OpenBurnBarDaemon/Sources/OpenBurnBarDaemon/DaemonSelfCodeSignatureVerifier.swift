import Foundation
import OpenBurnBarComputerUseCore
#if canImport(Darwin)
import Darwin
#endif

/// T-DMN-03 — pre-exec re-verification of the daemon's OWN on-disk binary.
///
/// Ideal control: install the daemon from a root-owned / SIP-protected location
/// via `SMAppService` so a same-uid attacker cannot swap the executable between
/// launches. That install-location change lives in the app/installer (the
/// `SMAppService` registration + the LaunchDaemon plist), which is OUTSIDE this
/// `OpenBurnBarDaemon/**` subtree, so it is tracked as Deferred.
///
/// What we CAN enforce here, in the daemon itself: when the daemon starts, it
/// re-verifies that its own on-disk image still satisfies the first-party
/// designated requirement (Apple anchor + Team ID + exact first-party identifier
/// + hardened runtime + library validation) using the same shared trust
/// primitive (`OpenBurnBarPrivilegedTrust.validateStaticCode(at:)`) that gates
/// socket peers. If a same-uid attacker swapped the user-writable installed
/// binary, the swapped image fails this check and the daemon refuses to come up,
/// rather than serving the full RPC/HID surface from an unsigned/foreign image.
///
/// This is a defense-in-depth complement to the install-location change, not a
/// substitute: an attacker who can swap the binary AND re-sign it with the
/// first-party identity is out of scope (they would already hold the signing
/// key). It is intentionally fail-open on platforms / build configurations that
/// genuinely cannot carry the first-party signature (unsigned developer builds),
/// mirroring how `BurnBarDaemonPeerAuthenticator` defaults to non-enforcing
/// there, and is wired enforcing only when the peer-codesig gate is enforced.
public struct DaemonSelfCodeSignatureVerifier: Sendable {
    public enum VerificationFailure: Error, Equatable, Sendable {
        case executablePathUnavailable
        case codeSignatureInvalid(status: OSStatus)
    }

    /// Resolves the absolute path of the currently-running executable image.
    /// Injectable so tests can drive a known good/bad path without spawning.
    public typealias ExecutablePathResolver = @Sendable () -> String?

    /// Validates the on-disk image at `url` against the first-party designated
    /// requirement. Injectable so tests exercise the policy without a
    /// first-party-signed image (which a unit-test host can never be).
    public typealias StaticCodeValidator = @Sendable (_ url: URL) throws -> Void

    /// `true` enforces the self-signature gate at startup; `false` makes
    /// ``verify()`` a no-op (unsigned developer builds). Production binds this to
    /// the same flag as the peer-codesig gate.
    public let isEnforced: Bool
    private let resolveExecutablePath: ExecutablePathResolver
    private let validateStaticCode: StaticCodeValidator
    private let logger: BurnBarDaemonLogger

    public init(
        enforced: Bool,
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "daemon-self-codesig"),
        resolveExecutablePath: @escaping ExecutablePathResolver = DaemonSelfCodeSignatureVerifier.defaultExecutablePath,
        validateStaticCode: @escaping StaticCodeValidator = DaemonSelfCodeSignatureVerifier.defaultStaticCodeValidation
    ) {
        self.isEnforced = enforced
        self.logger = logger
        self.resolveExecutablePath = resolveExecutablePath
        self.validateStaticCode = validateStaticCode
    }

    /// A no-op verifier (never checks). Default for in-process tests and unsigned
    /// developer builds, mirroring `BurnBarDaemonPeerAuthenticator.disabled`.
    public static let disabled = DaemonSelfCodeSignatureVerifier(enforced: false)

    /// Re-verify the running image's code signature. When enforcement is off this
    /// is a no-op. When on, any failure (path unreadable or signature invalid) is
    /// fail-closed and logged, and the caller MUST refuse to start.
    public func verify() throws {
        guard isEnforced else { return }

        guard let path = resolveExecutablePath(), path.isEmpty == false else {
            reject(.executablePathUnavailable)
            throw VerificationFailure.executablePathUnavailable
        }

        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        do {
            try validateStaticCode(url)
        } catch let failure as VerificationFailure {
            reject(failure)
            throw failure
        } catch PrivilegedSocketTrustError.codeSignatureInvalid(let status) {
            let wrapped = VerificationFailure.codeSignatureInvalid(status: status)
            reject(wrapped)
            throw wrapped
        } catch {
            let wrapped = VerificationFailure.codeSignatureInvalid(status: errSecCSReqFailed)
            reject(wrapped)
            throw wrapped
        }

        logger.notice("daemon_self_code_signature_verified", metadata: ["path": url.path])
    }

    private func reject(_ failure: VerificationFailure) {
        logger.error(
            "daemon_self_code_signature_rejected",
            metadata: ["detail": String(describing: failure)]
        )
    }

    /// Resolve the running executable path via `_NSGetExecutablePath`, then
    /// canonicalize. Returns `nil` if the platform cannot report it.
    @Sendable
    public static func defaultExecutablePath() -> String? {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
        #else
        return CommandLine.arguments.first
        #endif
    }

    /// Production validator: delegate to the shared first-party trust primitive
    /// and re-map its error into the self-verification failure space.
    @Sendable
    public static func defaultStaticCodeValidation(url: URL) throws {
        #if os(macOS)
        do {
            try OpenBurnBarPrivilegedTrust.validateStaticCode(at: url)
        } catch PrivilegedSocketTrustError.codeSignatureInvalid(let status) {
            throw VerificationFailure.codeSignatureInvalid(status: status)
        }
        #else
        _ = url
        #endif
    }
}
