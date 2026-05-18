import XCTest
@testable import OpenBurnBarIrohRelay
import OpenBurnBarCore

final class IrohRelayCryptoSpotCheckTests: XCTestCase {
    /// Sanity check: `HermesRelayCrypto.wrapSymmetricKey` round-trips with
    /// the same AAD. If this fails the echo test SIGTRAP is in the crypto
    /// layer; if it passes the bug is elsewhere.
    func testWrapUnwrapRoundTrip() throws {
        let priv = HermesRelayCrypto.generatePrivateKey()
        let symmetric = try HermesRelayCrypto.generateSymmetricKeyData()
        let aad = HermesRelayCrypto.keyAAD(uid: "u-1", connectionID: "c-1", requestID: "r-1")
        let wrapped = try HermesRelayCrypto.wrapSymmetricKey(
            symmetric,
            recipientPublicKeyBase64: priv.publicKeyBase64,
            aad: aad
        )
        let unwrapped = try HermesRelayCrypto.unwrapSymmetricKey(
            wrapped,
            privateKey: priv,
            aad: aad
        )
        XCTAssertEqual(unwrapped, symmetric)
    }

    func testFrameRoundTripWithPayload() throws {
        let priv = HermesRelayCrypto.generatePrivateKey()
        let symmetric = try HermesRelayCrypto.generateSymmetricKeyData()
        let requestAAD = HermesRelayCrypto.requestAAD(uid: "u", connectionID: "c", requestID: "r")
        let ciphertext = try HermesRelayCrypto.sealToBase64(
            plaintext: Data("hello".utf8),
            keyData: symmetric,
            aad: requestAAD
        )
        let opened = try HermesRelayCrypto.openBase64(
            ciphertext: ciphertext,
            keyData: symmetric,
            aad: requestAAD
        )
        XCTAssertEqual(String(data: opened, encoding: .utf8), "hello")
    }
}
