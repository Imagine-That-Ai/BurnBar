import XCTest
@testable import OpenBurnBarMobile

final class MercuryHostIdentityRecoveryTests: XCTestCase {
    func testPinMismatchErrorIsDetectedFromTypedErrorAndCopy() {
        let error = FirestoreIrohPairingPublicKeyError.hostKeyPinMismatch
        XCTAssertTrue(MercuryHostIdentityRecovery.isPinMismatch(error))
        XCTAssertTrue(MercuryHostIdentityRecovery.isPinMismatchMessage(error.errorDescription))
        XCTAssertEqual(
            MercuryHostIdentityRecovery.actionTitle(needsRePair: true),
            "Re-pair Mac"
        )
        XCTAssertEqual(
            MercuryHostIdentityRecovery.actionTitle(needsRePair: false),
            "Reconnect"
        )
    }

    func testOtherPairingErrorsDoNotRequestRePair() {
        XCTAssertFalse(
            MercuryHostIdentityRecovery.isPinMismatch(
                FirestoreIrohPairingPublicKeyError.publicKeyNotFound
            )
        )
        XCTAssertFalse(
            MercuryHostIdentityRecovery.isPinMismatchMessage(
                FirestoreIrohPairingPublicKeyError.publicKeyNotFound.errorDescription
            )
        )
        XCTAssertFalse(
            MercuryHostIdentityRecovery.isPinMismatchMessage("Preparing the Mac mirror control stream.")
        )
    }

    func testPublicKeyCacheDropsAClearedUID() async {
        let cache = PublicKeyCache()
        let key = Data(repeating: 7, count: 32)
        await cache.set(key, for: "uid-a")
        await cache.set(Data(repeating: 9, count: 32), for: "uid-b")
        await cache.remove(for: "uid-a")
        let removed = await cache.value(for: "uid-a")
        let remaining = await cache.value(for: "uid-b")
        XCTAssertNil(removed)
        XCTAssertEqual(remaining?.count, 32)
    }
}
