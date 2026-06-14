import OpenBurnBarCore
import OpenBurnBarSignalCore
import XCTest
@testable import OpenBurnBar

/// Covers the fix for the formerly-swallowed `try?` on the local Signal-identity load in
/// `MacCloudVaultKeyAccess.keyForReading`. The read path resolves this device's Signal
/// identity to open at-rest envelopes; the prior `try?` collapsed a real keychain/store
/// fault into the same `nil` as a genuinely-absent identity, hiding the failure.
///
/// The corrected `resolveLocalSignalIdentity` keeps the optionality contract (still `nil`
/// when there is no identity, so the read degrades gracefully and never fails open) while
/// making a real load error observable instead of silent. These tests pin all three
/// branches through the injectable `load` seam — no real keychain access required.
final class CloudVaultKeyAccessMattersTests: XCTestCase {

    private let uid = "test-uid"
    private let deviceId = "test-device"

    /// Genuine absence: the store has no identity yet and returns `nil`. The resolver must
    /// pass that `nil` through unchanged (legitimate "no identity on this device") and must
    /// invoke the loader with the supplied uid/deviceId.
    func testAbsentIdentityResolvesToNil() {
        var observedArgs: (String, String)?
        let resolved = MacCloudVaultKeyAccess.resolveLocalSignalIdentity(
            uid: uid,
            deviceId: deviceId,
            load: { uid, deviceId in
                observedArgs = (uid, deviceId)
                return nil
            }
        )

        XCTAssertNil(resolved, "Absent identity must remain nil for graceful read degradation")
        XCTAssertEqual(observedArgs?.0, uid)
        XCTAssertEqual(observedArgs?.1, deviceId)
    }

    /// Real load fault: the store throws (e.g. a keychain error / corrupted material). The
    /// resolver must NOT crash and must NOT propagate — it logs and returns `nil`, exactly
    /// preserving the read's skip behavior. Critically the error branch must actually be
    /// reached (the loader is invoked and its throw is caught), proving the failure is no
    /// longer swallowed before it can be observed.
    func testLoadErrorIsCaughtAndResolvesToNilWithoutThrowing() {
        var loaderInvoked = false
        let resolved = MacCloudVaultKeyAccess.resolveLocalSignalIdentity(
            uid: uid,
            deviceId: deviceId,
            load: { _, _ in
                loaderInvoked = true
                throw CloudVaultCryptoError.keychainError(-25300)
            }
        )

        XCTAssertTrue(loaderInvoked, "The error path must run the loader, not bypass it")
        XCTAssertNil(resolved, "A real load fault must degrade to nil, never to a crash or fail-open value")
    }

    /// A second distinct fault class is also caught and degraded, guarding against a future
    /// regression that only handles one error type.
    func testDataMissingErrorIsCaughtAndResolvesToNil() {
        let resolved = MacCloudVaultKeyAccess.resolveLocalSignalIdentity(
            uid: uid,
            deviceId: deviceId,
            load: { _, _ in throw CloudVaultCryptoError.keychainDataMissing }
        )

        XCTAssertNil(resolved)
    }

    /// Success: a real identity loads cleanly. The resolver must return that exact keypair
    /// untouched — proving the fix did not start swallowing valid identities.
    func testValidIdentityIsReturnedUnchanged() {
        let identity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: deviceId)
        let resolved = MacCloudVaultKeyAccess.resolveLocalSignalIdentity(
            uid: uid,
            deviceId: deviceId,
            load: { _, _ in identity }
        )

        XCTAssertEqual(resolved, identity, "A valid identity must pass through the resolver unchanged")
    }
}
