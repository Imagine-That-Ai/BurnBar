import Foundation
import OpenBurnBarCore
import XCTest

final class BurnBarDatabaseRecoveryBundleCryptoTests: XCTestCase {
    private let databaseKey = Data(repeating: 0x42, count: 32).base64EncodedString()

    func testMacCompatibleBundleRoundTripsDatabaseKey() throws {
        let bundle = try BurnBarDatabaseRecoveryBundleCrypto.export(
            databaseKey: databaseKey,
            passphrase: "unit test recovery phrase 42"
        )

        XCTAssertEqual(bundle.first, BurnBarDatabaseRecoveryBundleCrypto.version)
        XCTAssertGreaterThan(bundle.count, 21)
        XCTAssertEqual(
            try BurnBarDatabaseRecoveryBundleCrypto.importDatabaseKey(
                bundle: bundle,
                passphrase: "unit test recovery phrase 42"
            ),
            databaseKey
        )
    }

    func testWrongPassphraseAndTamperingFailClosed() throws {
        let bundle = try BurnBarDatabaseRecoveryBundleCrypto.export(
            databaseKey: databaseKey,
            passphrase: "correct horse battery staple"
        )
        XCTAssertThrowsError(
            try BurnBarDatabaseRecoveryBundleCrypto.importDatabaseKey(
                bundle: bundle,
                passphrase: "wrong passphrase"
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarDatabaseRecoveryBundleCrypto.Error, .authenticationFailed)
        }

        var tampered = bundle
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertThrowsError(
            try BurnBarDatabaseRecoveryBundleCrypto.importDatabaseKey(
                bundle: tampered,
                passphrase: "correct horse battery staple"
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarDatabaseRecoveryBundleCrypto.Error, .authenticationFailed)
        }
    }

    func testMalformedVersionIterationsAndKeysAreRejected() throws {
        XCTAssertThrowsError(
            try BurnBarDatabaseRecoveryBundleCrypto.export(
                databaseKey: "not-base64",
                passphrase: "password"
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarDatabaseRecoveryBundleCrypto.Error, .invalidDatabaseKey)
        }

        XCTAssertThrowsError(
            try BurnBarDatabaseRecoveryBundleCrypto.importDatabaseKey(
                bundle: Data(repeating: 0, count: 40),
                passphrase: "password"
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarDatabaseRecoveryBundleCrypto.Error, .unsupportedVersion(0))
        }

        let valid = try BurnBarDatabaseRecoveryBundleCrypto.export(databaseKey: databaseKey, passphrase: "password")
        var invalidIterations = valid
        invalidIterations[17] = 0
        invalidIterations[18] = 0
        invalidIterations[19] = 0
        invalidIterations[20] = 1
        XCTAssertThrowsError(
            try BurnBarDatabaseRecoveryBundleCrypto.importDatabaseKey(
                bundle: invalidIterations,
                passphrase: "password"
            )
        ) { error in
            XCTAssertEqual(error as? BurnBarDatabaseRecoveryBundleCrypto.Error, .invalidIterationCount(1))
        }
    }

    func testDeviceTransferResponseSeparatesStoredKeyFromDatabaseProof() throws {
        let response = BurnBarDatabaseRecoveryBundleImportResponse(
            sourcePath: "/tmp/recovery.obb",
            stored: true
        )

        XCTAssertTrue(response.stored)
        XCTAssertFalse(response.candidateKeyVerified)
        XCTAssertFalse(response.databaseIntegrityVerified)
        XCTAssertEqual(response.phase, .awaitingDatabaseVerification)
        XCTAssertEqual(response.recommendedAction, .restoreEncryptedSnapshot)

        let roundTrip = try JSONDecoder().decode(
            BurnBarDatabaseRecoveryBundleImportResponse.self,
            from: JSONEncoder().encode(response)
        )
        XCTAssertEqual(roundTrip, response)
    }

    func testRecoveryStatusNeverUsesKeyCustodyAsIntegrityProof() throws {
        let status = BurnBarDatabaseRecoveryStatusResponse(
            phase: .keyUnavailable,
            code: "database_key_unavailable",
            message: "Unlock the key store or import a recovery bundle.",
            recommendedAction: .importRecoveryBundle,
            canExport: false,
            canImport: true,
            databasePresent: true,
            databaseIntegrityVerified: false
        )

        XCTAssertFalse(status.databaseIntegrityVerified)
        XCTAssertEqual(status.recommendedAction, .importRecoveryBundle)
        let encoded = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(BurnBarDatabaseRecoveryStatusResponse.self, from: encoded)
        XCTAssertEqual(decoded, status)
    }
}
