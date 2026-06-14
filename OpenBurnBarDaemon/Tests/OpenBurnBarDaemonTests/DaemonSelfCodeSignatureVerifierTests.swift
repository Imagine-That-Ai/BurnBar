import Foundation
import OpenBurnBarComputerUseCore
import Security
@testable import OpenBurnBarDaemon
import XCTest

/// T-DMN-03: the daemon re-verifies its OWN on-disk image against the first-party
/// designated requirement at startup, so a same-uid attacker who swapped the
/// user-writable installed binary cannot bring up a foreign image. The
/// install-location change (root-owned SMAppService) lives in the app/installer
/// and is tracked Deferred; this proves the in-daemon pre-exec re-verification.
final class DaemonSelfCodeSignatureVerifierTests: XCTestCase {
    func test_disabledVerifierIsNoOp() {
        let verifier = DaemonSelfCodeSignatureVerifier(
            enforced: false,
            resolveExecutablePath: { "/should/not/matter" },
            validateStaticCode: { _ in throw DaemonSelfCodeSignatureVerifier.VerificationFailure.codeSignatureInvalid(status: -1) }
        )
        XCTAssertNoThrow(try verifier.verify())
    }

    func test_enforced_refusesWhenSignatureInvalid() {
        let verifier = DaemonSelfCodeSignatureVerifier(
            enforced: true,
            resolveExecutablePath: { "/usr/bin/true" },
            validateStaticCode: { _ in
                throw PrivilegedSocketTrustError.codeSignatureInvalid(status: errSecCSReqFailed)
            }
        )
        XCTAssertThrowsError(try verifier.verify()) { error in
            XCTAssertEqual(
                error as? DaemonSelfCodeSignatureVerifier.VerificationFailure,
                .codeSignatureInvalid(status: errSecCSReqFailed)
            )
        }
    }

    func test_enforced_refusesWhenExecutablePathUnavailable() {
        let verifier = DaemonSelfCodeSignatureVerifier(
            enforced: true,
            resolveExecutablePath: { nil },
            validateStaticCode: { _ in }
        )
        XCTAssertThrowsError(try verifier.verify()) { error in
            XCTAssertEqual(
                error as? DaemonSelfCodeSignatureVerifier.VerificationFailure,
                .executablePathUnavailable
            )
        }
    }

    func test_enforced_passesWhenValidatorAccepts() {
        var validatedURL: URL?
        let verifier = DaemonSelfCodeSignatureVerifier(
            enforced: true,
            resolveExecutablePath: { "/usr/bin/true" },
            validateStaticCode: { url in validatedURL = url }
        )
        XCTAssertNoThrow(try verifier.verify())
        XCTAssertEqual(validatedURL?.path, "/usr/bin/true")
    }

    func test_defaultExecutablePath_resolvesARealExistingFile() throws {
        let path = try XCTUnwrap(DaemonSelfCodeSignatureVerifier.defaultExecutablePath())
        XCTAssertFalse(path.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "resolved executable path must exist on disk")
    }

    func test_defaultStaticCodeValidation_rejectsUnsignedHelperBinary() {
        // /usr/bin/true is Apple-signed but is NOT the first-party OpenBurnBar
        // daemon, so the designated requirement must reject it — proving the
        // production default fails closed against a non-first-party image.
        XCTAssertThrowsError(
            try DaemonSelfCodeSignatureVerifier.defaultStaticCodeValidation(url: URL(fileURLWithPath: "/usr/bin/true"))
        ) { error in
            guard case DaemonSelfCodeSignatureVerifier.VerificationFailure.codeSignatureInvalid = error else {
                return XCTFail("expected codeSignatureInvalid, got \(error)")
            }
        }
    }
}
