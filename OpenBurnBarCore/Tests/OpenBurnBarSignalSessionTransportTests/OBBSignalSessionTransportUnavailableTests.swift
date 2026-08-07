import Foundation
import OpenBurnBarSignalSessionTransport
import XCTest

final class OBBSignalSessionTransportUnavailableTests: XCTestCase {
    func testLinuxPlaceholder() {}

    #if !canImport(LibSignalClient)
    func testFallbackProviderFailsClosedForSealAndOpen() async {
        let provider = OBBSignalSessionGatewayEnvelopeProvider()

        do {
            _ = try await provider.seal(
                plaintext: Data("test".utf8),
                uid: "uid",
                clientId: "client",
                slotId: "slot"
            )
            XCTFail("Fallback Signal transport must reject sealing.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
        }

        do {
            _ = try await provider.open(
                envelopeData: Data("test".utf8),
                uid: "uid",
                clientId: "client",
                slotId: "slot"
            )
            XCTFail("Fallback Signal transport must reject opening.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unavailable"))
        }
    }
    #endif
}
