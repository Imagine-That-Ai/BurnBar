import XCTest
import CryptoKit
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// T-ATT-04 / T-ATT-06 — Mercury inbound security primitives for the iOS receive
/// path: the sender-bound manifest MAC and the fail-closed seal-at-rest policy.
final class MercuryInboundSecurityTests: XCTestCase {

    private func manifest(
        blobHash: String = "blob-abc",
        filename: String = "report.pdf",
        mime: String = "application/pdf",
        size: Int64 = 1024
    ) -> HermesRealtimeRelayAttachmentManifest {
        HermesRealtimeRelayAttachmentManifest(
            manifestId: "m-1",
            blobHash: blobHash,
            filename: filename,
            mime: mime,
            size: size
        )
    }

    // MARK: T-ATT-04 — sender-bound MAC

    func testMACVerifiesForUntamperedManifest() {
        let key = SymmetricKey(size: .bits256)
        let m = manifest()
        let tag = MercuryManifestMAC.tag(manifest: m, key: key)
        XCTAssertTrue(MercuryManifestMAC.verify(expectedTagBase64: tag, manifest: m, key: key))
    }

    func testMACFailsWhenFilenameTampered() {
        let key = SymmetricKey(size: .bits256)
        let tag = MercuryManifestMAC.tag(manifest: manifest(filename: "report.pdf"), key: key)
        let tampered = manifest(filename: "invoice.exe")
        XCTAssertFalse(MercuryManifestMAC.verify(expectedTagBase64: tag, manifest: tampered, key: key))
    }

    func testMACFailsWhenSizeTampered() {
        let key = SymmetricKey(size: .bits256)
        let tag = MercuryManifestMAC.tag(manifest: manifest(size: 1024), key: key)
        let tampered = manifest(size: 999_999)
        XCTAssertFalse(MercuryManifestMAC.verify(expectedTagBase64: tag, manifest: tampered, key: key))
    }

    func testMACFailsUnderWrongKey() {
        let tag = MercuryManifestMAC.tag(manifest: manifest(), key: SymmetricKey(size: .bits256))
        XCTAssertFalse(MercuryManifestMAC.verify(expectedTagBase64: tag, manifest: manifest(), key: SymmetricKey(size: .bits256)))
    }

    func testMACRejectsMalformedTag() {
        let key = SymmetricKey(size: .bits256)
        XCTAssertFalse(MercuryManifestMAC.verify(expectedTagBase64: "not base64 @@@", manifest: manifest(), key: key))
    }

    func testLengthDelimitedTranscriptResistsFieldShifting() {
        // ("ab","") must not collide with ("a","b") — length prefixes prevent it.
        let key = SymmetricKey(size: .bits256)
        let tagAB = MercuryManifestMAC.tag(blobHash: "h", filename: "ab", mime: "", size: 1, key: key)
        let tagA_B = MercuryManifestMAC.tag(blobHash: "h", filename: "a", mime: "b", size: 1, key: key)
        XCTAssertNotEqual(tagAB, tagA_B)
    }

    // MARK: T-ATT-06 — fail-closed seal-at-rest policy

    func testSealAtRestRequiredByDefault() {
        let suite = "MercuryInboxSecurityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        XCTAssertTrue(
            MercuryInboxSecurityPolicy.sealAtRestRequired(defaults: defaults),
            "A received blob with no seal key must be refused by default, not kept as plaintext."
        )
    }

    func testSealAtRestPolicyOverridable() {
        let suite = "MercuryInboxSecurityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: MercuryInboxSecurityPolicy.userDefaultsKey)
        XCTAssertFalse(MercuryInboxSecurityPolicy.sealAtRestRequired(defaults: defaults))
    }

    func testAtRestGopIDIsStablePerManifest() {
        let a = iOSFileTransferService.atRestGopID(for: manifest())
        let b = iOSFileTransferService.atRestGopID(for: manifest())
        XCTAssertEqual(a, b)
    }
}
