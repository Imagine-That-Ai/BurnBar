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
}
