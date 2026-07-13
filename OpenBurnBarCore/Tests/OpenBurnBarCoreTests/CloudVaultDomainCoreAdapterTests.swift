import Foundation
import XCTest
@testable import OpenBurnBarCore

final class CloudVaultDomainCoreAdapterTests: XCTestCase {
    private let rustEnvironment = [
        "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE": "rust",
        "OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE": "1"
    ]

    func testNativeRustModeMatchesCanonicalCloudVaultKAT() throws {
        XCTAssertTrue(CloudVaultDomainCoreAdapter.isNativeAvailable)
        let fixture = try loadFixture()

        for vector in fixture.aad {
            XCTAssertEqual(
                try CloudVaultDomainCoreAdapter.aadV1(
                    uid: vector.uid,
                    collection: vector.collection,
                    docID: vector.docID,
                    field: vector.field,
                    environment: rustEnvironment,
                    legacy: { XCTFail("Rust mode evaluated the AAD v1 legacy closure"); return "" }
                ),
                vector.v1
            )
            XCTAssertEqual(
                try CloudVaultDomainCoreAdapter.aadV2(
                    uid: vector.uid,
                    collection: vector.collection,
                    docID: vector.docID,
                    field: vector.field,
                    schemaVersion: vector.schemaVersion,
                    purpose: vector.purpose,
                    environment: rustEnvironment,
                    legacy: { XCTFail("Rust mode evaluated the AAD v2 legacy closure"); return "" }
                ),
                vector.v2
            )
        }

        for vector in fixture.sha256 {
            let data = try Data(hex: vector.dataHex)
            XCTAssertEqual(
                try CloudVaultDomainCoreAdapter.sha256Hex(
                    data,
                    environment: rustEnvironment,
                    legacy: { XCTFail("Rust mode evaluated the SHA-256 legacy closure"); return "" }
                ),
                vector.hex
            )
        }

        for vector in fixture.vaultKeyID {
            let key = try Data(hex: vector.keyHex)
            XCTAssertEqual(
                try CloudVaultDomainCoreAdapter.vaultKeyID(
                    for: key,
                    environment: rustEnvironment,
                    legacy: { XCTFail("Rust mode evaluated the key ID legacy closure"); return "" }
                ),
                vector.value
            )
        }

        for vector in fixture.keyedHashes {
            let data = try Data(hex: vector.dataHex)
            let key = try Data(hex: vector.keyHex)
            XCTAssertEqual(
                try CloudVaultDomainCoreAdapter.keyedHashHex(
                    data,
                    keyData: key,
                    purpose: try purpose(vector.purpose),
                    environment: rustEnvironment,
                    legacy: { XCTFail("Rust mode evaluated a keyed-hash legacy closure"); return "" }
                ),
                vector.hex
            )
        }

        let body = Data("the quick brown fox jumps over the lazy dog".utf8)
        let bodyKey = try Data(hex: fixture.keyedHashes[0].keyHex)
        for vector in fixture.expectedSessionBodyHash {
            XCTAssertEqual(
                try CloudVaultDomainCoreAdapter.expectedSessionBodyHash(
                    body,
                    keyData: bodyKey,
                    bodyHashVersion: vector.bodyHashVersion,
                    environment: rustEnvironment,
                    legacy: { XCTFail("Rust mode evaluated the expected-hash legacy closure"); return "" }
                ),
                vector.hex
            )
        }
    }

    func testShadowReturnsLegacyAndDiagnosticsNeverContainSecretsOrHashes() throws {
        let logger = RecordingCloudVaultDomainCoreLogger()
        let secret = "private-session-body"
        let key = Data(repeating: 0x7a, count: 32)
        let rustHash = try CloudVaultDomainCoreAdapter.keyedHashHex(
            Data(secret.utf8),
            keyData: key,
            purpose: .sessionBody,
            environment: ["OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE": "rust"],
            legacy: { "unused" }
        )

        let result = try CloudVaultDomainCoreAdapter.keyedHashHex(
            Data(secret.utf8),
            keyData: key,
            purpose: .sessionBody,
            environment: ["OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE": "shadow"],
            logger: logger,
            legacy: { "legacy-result" }
        )

        XCTAssertEqual(result, "legacy-result")
        let diagnostic = try XCTUnwrap(logger.messages.first)
        XCTAssertTrue(diagnostic.contains("operation=session_body_hash"))
        XCTAssertTrue(diagnostic.contains("category=value_mismatch"))
        XCTAssertFalse(diagnostic.contains(secret))
        XCTAssertFalse(diagnostic.contains(key.base64EncodedString()))
        XCTAssertFalse(diagnostic.contains(rustHash))
        XCTAssertFalse(diagnostic.contains("legacy-result"))
    }

    func testLegacyModeDoesNotRequireNativeAndEvaluatesOnlyLegacy() throws {
        var evaluations = 0
        let result = try CloudVaultDomainCoreAdapter.sha256Hex(
            Data("legacy".utf8),
            environment: [
                "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE": "legacy",
                "OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE": "1"
            ],
            legacy: {
                evaluations += 1
                return "legacy-value"
            }
        )
        XCTAssertEqual(result, "legacy-value")
        XCTAssertEqual(evaluations, 1)
    }

    func testRustValidationFailuresFailClosedThroughPublicAPI() throws {
        XCTAssertThrowsError(
            try CloudVaultCrypto.vaultKeyID(for: Data(repeating: 0, count: 31))
        ) { error in
            guard case CloudVaultCryptoError.invalidKeyLength = error else {
                return XCTFail("Expected invalidKeyLength, got \(error)")
            }
        }

        let key = Data(repeating: 0x11, count: 32)
        XCTAssertThrowsError(
            try CloudVaultDomainCoreAdapter.expectedSessionBodyHash(
                Data("body".utf8),
                keyData: key,
                bodyHashVersion: 99,
                environment: rustEnvironment,
                legacy: { "must-not-run" }
            )
        ) { error in
            XCTAssertEqual(error as? CloudVaultDomainCoreAdapterError, .invalidInput)
        }

        let context = try CloudVaultAADContext(
            uid: "u",
            collection: "c",
            docID: "d",
            field: "f"
        )
        XCTAssertThrowsError(
            try CloudVaultDomainCoreAdapter.resolveAAD(
                envelopeAAD: "wrong-aad",
                context: context,
                rejectLegacyV1: true,
                environment: rustEnvironment,
                legacy: { Data("must-not-run".utf8) }
            )
        ) { error in
            XCTAssertEqual(error as? CloudVaultDomainCoreAdapterError, .invalidInput)
        }
    }

    private func purpose(_ value: String) throws -> CloudVaultDomainCoreAdapter.Purpose {
        switch value {
        case "blob-integrity": .blobIntegrity
        case "session-body": .sessionBody
        case "session-chunk": .sessionChunk
        case "project-memory-content": .projectMemoryContent
        default: throw FixtureError.unknownPurpose
        }
    }

    private func loadFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(
            "tests/fixtures/domain-core/cloudvault/v1/cloudvault-deterministic-kat.json"
        )
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

private final class RecordingCloudVaultDomainCoreLogger: CloudVaultDomainCoreLogging, @unchecked Sendable {
    private(set) var messages: [String] = []

    func log(_ message: String) {
        messages.append(message)
    }
}

private enum FixtureError: Error {
    case invalidHex
    case unknownPurpose
}

private struct Fixture: Decodable {
    let aad: [AAD]
    let sha256: [SHA256]
    let vaultKeyID: [VaultKeyID]
    let keyedHashes: [KeyedHash]
    let expectedSessionBodyHash: [ExpectedSessionBodyHash]

    struct AAD: Decodable {
        let uid: String
        let collection: String
        let docID: String
        let field: String
        let schemaVersion: Int
        let purpose: String
        let v1: String
        let v2: String
    }

    struct SHA256: Decodable {
        let dataHex: String
        let hex: String
    }

    struct VaultKeyID: Decodable {
        let keyHex: String
        let value: String
    }

    struct KeyedHash: Decodable {
        let purpose: String
        let keyHex: String
        let dataHex: String
        let hex: String
    }

    struct ExpectedSessionBodyHash: Decodable {
        let bodyHashVersion: Int
        let hex: String
    }
}

private extension Data {
    init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else { throw FixtureError.invalidHex }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw FixtureError.invalidHex
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
