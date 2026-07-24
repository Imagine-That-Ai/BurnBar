import Foundation
@testable import OpenBurnBarLinuxSecurity
import XCTest

final class LinuxAuthTokenStoreValueTests: XCTestCase {
    func testRefreshTokenValueIsAvailableOnlyThroughExplicitSecretAccessor() throws {
        let backend = LinuxInMemorySecretStoreBackend(
            secrets: ["firebase-refresh-token": "refresh-secret-value"]
        )
        let store = LinuxAuthTokenStore(custodian: LinuxSecretCustodian(backends: [backend]))

        XCTAssertEqual(try store.requireRefreshTokenValue(), "refresh-secret-value")
        let metadata = try store.restoreRefreshToken()
        XCTAssertEqual(metadata.id, "firebase-refresh-token")
        XCTAssertFalse(metadata.note.contains("refresh-secret-value"))
    }

    func testMissingRefreshTokenFailsClosed() {
        let store = LinuxAuthTokenStore(
            custodian: LinuxSecretCustodian(backends: [
                LinuxInMemorySecretStoreBackend(secrets: [:])
            ])
        )
        XCTAssertThrowsError(try store.requireRefreshTokenValue()) { error in
            XCTAssertEqual(error as? LinuxSecretStoreError, .missingSecret("firebase-refresh-token"))
        }
    }
}
