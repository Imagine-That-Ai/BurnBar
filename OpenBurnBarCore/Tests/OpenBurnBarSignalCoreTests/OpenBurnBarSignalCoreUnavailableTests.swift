#if !canImport(LibSignalClient)
import XCTest
import OpenBurnBarCore
import OpenBurnBarSignalCore

final class OpenBurnBarSignalCoreUnavailableTests: XCTestCase {
    func testLinuxContractImportReportsMissingLibSignalImplementation() throws {
        XCTAssertFalse(OpenBurnBarSignalCoreAvailability.isLibSignalBacked)
        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.atRestSeal(
                Data("payload".utf8),
                recipientIdentityPublicKey: Data(repeating: 1, count: 32),
                binding: SignalEnvelopeAAD.Binding(
                    uid: "uid",
                    scope: .cloudvault,
                    collection: "sessions",
                    docId: "doc",
                    field: "body",
                    mode: .atRest,
                    formatVersion: 1
                )
            )
        ) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .libSignalUnavailable)
        }
    }
}
#endif
