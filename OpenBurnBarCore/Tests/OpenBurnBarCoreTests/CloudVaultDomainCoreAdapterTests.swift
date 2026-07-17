import Foundation
import OpenBurnBarDomainCoreRuntime
import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarKernel

final class CloudVaultDomainCoreAdapterTests: XCTestCase {
    private let rustEnvironment = [
        "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE": "rust",
        "OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE": "1"
    ]

    override func setUpWithError() throws {
        try XCTSkipUnless(
            CloudVaultDomainCoreAdapter.isNativeAvailable,
            "CloudVault native contracts require the optional domain-core XCFramework"
        )
    }

    func testNativeRustModeMatchesCanonicalCloudVaultKAT() throws {
        XCTAssertTrue(CloudVaultDomainCoreAdapter.isNativeAvailable)
        XCTAssertEqual(DomainCoreNativeProbe.abiVersion(), 3)
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

        for vector in fixture.aesGcm {
            let key = try Data(hex: vector.keyHex)
            let nonce = try Data(hex: vector.nonceHex)
            let plaintext = try Data(hex: vector.plaintextHex)
            let aad = try Data(hex: vector.aadHex)
            let expectedCiphertext = try Data(hex: vector.ciphertextHex)
            let expectedTag = try Data(hex: vector.tagHex)
            let sealed = try CloudVaultDomainCoreAdapter.sealAESGCMDetached(
                plaintext: plaintext,
                keyData: key,
                nonce: nonce,
                authenticating: aad,
                environment: rustEnvironment,
                legacy: { XCTFail("Rust mode evaluated the AES legacy closure"); throw FixtureError.unexpectedLegacy }
            )
            XCTAssertEqual(sealed.nonce, nonce)
            XCTAssertEqual(sealed.ciphertext, expectedCiphertext)
            XCTAssertEqual(sealed.tag, expectedTag)
            XCTAssertEqual(
                try CloudVaultDomainCoreAdapter.base64Encode(
                    sealed.combined,
                    environment: rustEnvironment,
                    legacy: { XCTFail("Rust mode evaluated the Base64 legacy closure"); return "" }
                ),
                vector.combinedBase64
            )
            XCTAssertEqual(
                try CloudVaultDomainCoreAdapter.openAESGCMCombined(
                    combined: sealed.combined,
                    keyData: key,
                    authenticating: aad,
                    environment: rustEnvironment,
                    legacy: { XCTFail("Rust mode evaluated the AES legacy closure"); return Data() }
                ),
                plaintext
            )
        }
    }

    func testNativeRustModeMatchesOpaqueIdentifierKATWithoutLegacyFallback() throws {
        let key = Data((0 ..< 32).map(UInt8.init))
        let neverLegacy: () throws -> String = {
            XCTFail("Rust mode evaluated an opaque-identifier legacy closure")
            return ""
        }

        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.projectMemoryDocID(
                slug: "la-hormiga-dormida",
                keyData: key,
                environment: rustEnvironment,
                legacy: neverLegacy
            ),
            "pm_445f38c87b0e3c474c2be6339b8cd8d8"
        )
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.pensieveDedupHash(
                plaintext: "deploy the daemon before midnight",
                keyData: key,
                environment: rustEnvironment,
                legacy: neverLegacy
            ),
            "e55f699579cba539fb8f3a87c77bd768a95e331859c9fca9c89d21dac0c6d433"
        )
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.pensieveSlugHmac(
                slug: "burnbar-docs-secret-runbook",
                keyData: key,
                environment: rustEnvironment,
                legacy: neverLegacy
            ),
            "f77ecba2eaa6012fb4a6846d8fd218b61a04094cad346683f029e1636da7a96d"
        )
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.subscriptionDocID(
                agentURI: "agent://burnbar/research-scout",
                topicID: "agent-updates",
                keyData: key,
                environment: rustEnvironment,
                legacy: neverLegacy
            ),
            "sub_4b6aff30300ab361ad751d8d7c6b2bb0"
        )
    }

    func testNativeRustModeMatchesRecoveryAndP256EscrowKAT() throws {
        let fixture = try loadFixture()
        let recovery = fixture.recovery
        let vaultKey = try Data(hex: recovery.vaultKeyHex)
        let nonce = try Data(hex: recovery.nonceHex)
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.normalizeRecoveryKey(
                recovery.formattedKey,
                environment: rustEnvironment,
                legacy: { XCTFail("Rust mode evaluated recovery normalization legacy closure"); return "" }
            ),
            recovery.normalizedKey
        )
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.recoveryWrappingKey(
                recoveryKey: recovery.formattedKey,
                environment: rustEnvironment,
                legacy: { XCTFail("Rust mode evaluated recovery KDF legacy closure"); return Data() }
            ),
            try Data(hex: recovery.wrappingKeyHex)
        )
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.normalizeRecoveryKey(
                recovery.unicodeFormattedKey,
                environment: rustEnvironment,
                legacy: { XCTFail("Rust mode evaluated Unicode normalization legacy closure"); return "" }
            ),
            recovery.unicodeNormalizedKey
        )
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.recoveryWrappingKey(
                recoveryKey: recovery.unicodeFormattedKey,
                environment: rustEnvironment,
                legacy: { XCTFail("Rust mode evaluated Unicode recovery KDF legacy closure"); return Data() }
            ),
            try Data(hex: recovery.unicodeWrappingKeyHex)
        )
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.recoveryVerificationHash(
                recoveryKey: recovery.formattedKey,
                environment: rustEnvironment,
                legacy: { XCTFail("Rust mode evaluated recovery verification legacy closure"); return "" }
            ),
            recovery.verificationHash
        )
        let wrapped = try CloudVaultDomainCoreAdapter.recoveryWrapVaultKey(
            vaultKey: vaultKey,
            recoveryKey: recovery.formattedKey,
            nonce: nonce,
            environment: rustEnvironment,
            legacy: { XCTFail("Rust mode evaluated recovery wrap legacy closure"); throw FixtureError.unexpectedLegacy }
        )
        XCTAssertEqual(wrapped.combined, try Data(hex: recovery.combinedHex))
        XCTAssertEqual(wrapped.verificationHash, recovery.verificationHash)
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.recoveryOpenVaultKey(
                combined: wrapped.combined,
                recoveryKey: recovery.formattedKey,
                environment: rustEnvironment,
                legacy: { XCTFail("Rust mode evaluated recovery open legacy closure"); return Data() }
            ),
            vaultKey
        )

        let escrow = fixture.p256Escrow
        let publicKey = try Data(hex: escrow.ephemeralPublicKeyHex)
        let sharedSecret = try Data(hex: escrow.sharedSecretHex)
        let plaintext = try Data(hex: escrow.plaintextHex)
        let escrowNonce = try Data(hex: escrow.nonceHex)
        try CloudVaultDomainCoreAdapter.validateP256X963PublicKey(
            publicKey,
            environment: rustEnvironment,
            legacy: { XCTFail("Rust mode evaluated P-256 validation legacy closure"); return false }
        )
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.escrowWrappingKey(
                sharedSecret: sharedSecret,
                environment: rustEnvironment,
                legacy: { XCTFail("Rust mode evaluated escrow KDF legacy closure"); return Data() }
            ),
            try Data(hex: escrow.wrappingKeyHex)
        )
        let wire = try CloudVaultDomainCoreAdapter.escrowSeal(
            plaintext: plaintext,
            ephemeralPublicKey: publicKey,
            sharedSecret: sharedSecret,
            nonce: escrowNonce,
            environment: rustEnvironment,
            legacy: { XCTFail("Rust mode evaluated escrow seal legacy closure"); return Data() }
        )
        XCTAssertEqual(wire, try Data(hex: escrow.wireHex))
        let parts = try CloudVaultDomainCoreAdapter.escrowSplitWire(
            wire,
            environment: rustEnvironment,
            legacy: { XCTFail("Rust mode evaluated escrow split legacy closure"); throw FixtureError.unexpectedLegacy }
        )
        XCTAssertEqual(parts.ephemeralPublicKey, publicKey)
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.escrowAssembleWire(
                ephemeralPublicKey: parts.ephemeralPublicKey,
                aesGCMCombined: parts.aesGCMCombined,
                environment: rustEnvironment,
                legacy: { XCTFail("Rust mode evaluated escrow assemble legacy closure"); return Data() }
            ),
            wire
        )
        XCTAssertEqual(
            try CloudVaultDomainCoreAdapter.escrowOpen(
                wire: wire,
                sharedSecret: sharedSecret,
                environment: rustEnvironment,
                legacy: { XCTFail("Rust mode evaluated escrow open legacy closure"); return Data() }
            ),
            plaintext
        )
    }

    func testC1cShadowDiagnosticsAreSecretFreeAndLegacyAuthoritative() throws {
        let logger = RecordingCloudVaultDomainCoreLogger()
        let recoveryKey = "abc-defg-hjkm-npq-rst-vwxyz-23456789"
        let result = try CloudVaultDomainCoreAdapter.recoveryVerificationHash(
            recoveryKey: recoveryKey,
            environment: ["OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE": "shadow"],
            logger: logger,
            legacy: { "legacy-verification" }
        )
        XCTAssertEqual(result, "legacy-verification")
        let diagnostic = try XCTUnwrap(logger.messages.first)
        XCTAssertTrue(diagnostic.contains("operation=recovery_verification_hash"))
        XCTAssertTrue(diagnostic.contains("version=3"))
        XCTAssertTrue(diagnostic.contains("category=value_mismatch"))
        XCTAssertFalse(diagnostic.contains(recoveryKey))
        XCTAssertFalse(diagnostic.contains("legacy-verification"))
        XCTAssertFalse(diagnostic.contains("3d3722923f9209d63093b1212a55b5fb5de462c00137ba6d6b46228404873166"))
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
        XCTAssertTrue(diagnostic.contains("version=3"))
        XCTAssertTrue(diagnostic.contains("category=value_mismatch"))
        XCTAssertFalse(diagnostic.contains(secret))
        XCTAssertFalse(diagnostic.contains(key.base64EncodedString()))
        XCTAssertFalse(diagnostic.contains(rustHash))
        XCTAssertFalse(diagnostic.contains("legacy-result"))
    }

    func testShadowPreservesLegacyFailureBeforeRustValidation() {
        let logger = RecordingCloudVaultDomainCoreLogger()

        XCTAssertThrowsError(
            try CloudVaultDomainCoreAdapter.aadV2(
                uid: "user",
                collection: "sessions",
                docID: "document",
                field: "body",
                schemaVersion: -1,
                purpose: "body",
                environment: ["OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE": "shadow"],
                logger: logger,
                legacy: { throw FixtureError.unexpectedLegacy }
            )
        ) { error in
            guard case FixtureError.unexpectedLegacy = error else {
                return XCTFail("Expected exact legacy failure, got \(error)")
            }
        }
        XCTAssertTrue(logger.messages.isEmpty)
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

    func testRustAESRejectsNonCanonicalBase64WithoutLegacyFallback() throws {
        var legacyEvaluations = 0
        XCTAssertThrowsError(
            try CloudVaultDomainCoreAdapter.base64DecodeStrict(
                "AA==\n",
                environment: rustEnvironment,
                legacy: {
                    legacyEvaluations += 1
                    return Data([0])
                }
            )
        ) { error in
            XCTAssertEqual(error as? CloudVaultDomainCoreAdapterError, .invalidInput)
        }
        XCTAssertEqual(legacyEvaluations, 0)
    }

    func testRustAESRejectsInvalidUTF8AndAuthenticationFailureWithoutLegacyFallback() throws {
        let key = Data(repeating: 0x42, count: 32)
        let nonce = Data(repeating: 0x24, count: 12)
        let aad = Data("aad".utf8)
        let invalidUTF8 = try CloudVaultDomainCoreAdapter.sealAESGCMDetached(
            plaintext: Data([0xFF]),
            keyData: key,
            nonce: nonce,
            authenticating: aad,
            environment: rustEnvironment,
            legacy: { throw FixtureError.unexpectedLegacy }
        )

        var legacyEvaluations = 0
        XCTAssertThrowsError(
            try CloudVaultDomainCoreAdapter.openAESGCMTextDetached(
                nonce: invalidUTF8.nonce,
                ciphertext: invalidUTF8.ciphertext,
                tag: invalidUTF8.tag,
                keyData: key,
                authenticating: aad,
                environment: rustEnvironment,
                legacy: {
                    legacyEvaluations += 1
                    return "legacy"
                }
            )
        )

        var tamperedTag = invalidUTF8.tag
        tamperedTag[tamperedTag.startIndex] ^= 0x01
        XCTAssertThrowsError(
            try CloudVaultDomainCoreAdapter.openAESGCMDetached(
                nonce: invalidUTF8.nonce,
                ciphertext: invalidUTF8.ciphertext,
                tag: tamperedTag,
                keyData: key,
                authenticating: aad,
                environment: rustEnvironment,
                legacy: {
                    legacyEvaluations += 1
                    return Data()
                }
            )
        )
        XCTAssertEqual(legacyEvaluations, 0)
    }

    func testShadowAESUsesIdenticalExplicitNonceAndReturnsLegacy() throws {
        let key = Data(repeating: 0x11, count: 32)
        let nonce = Data(repeating: 0x22, count: 12)
        let plaintext = Data("shadow".utf8)
        let aad = Data("aad".utf8)
        var legacyEvaluations = 0
        let result = try CloudVaultDomainCoreAdapter.sealAESGCMDetached(
            plaintext: plaintext,
            keyData: key,
            nonce: nonce,
            authenticating: aad,
            environment: ["OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE": "shadow"],
            legacy: {
                legacyEvaluations += 1
                let sealed = try PlatformCrypto.sealAESGCMDetached(
                    plaintext: plaintext,
                    keyData: key,
                    nonce: nonce,
                    authenticating: aad
                )
                return .init(nonce: sealed.nonce, ciphertext: sealed.ciphertext, tag: sealed.tag)
            }
        )
        XCTAssertEqual(result.nonce, nonce)
        XCTAssertEqual(legacyEvaluations, 1)
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

/// Regressions for the CloudVault opaque-identifier shadow slice routing defect.
///
/// On the pre-fix head `recordComparison` mapped `project_memory_doc_id`,
/// `pensieve_dedup_hash`, `pensieve_slug_hmac`, and `subscription_doc_id` to the
/// `foundation` slice (none of the `if/else if` clauses matched those
/// operations), so Apple shadow comparisons carried the wrong slice and were
/// dropped by spool validation. These tests exercise the public adapter entry
/// points in shadow mode and assert the recorded `DomainCoreShadowComparison`
/// carries `slice == "opaque-identifiers"`. They do NOT require the native
/// domain-core XCFramework: shadow mode records a `native_unavailable`
/// comparison through the `#else` branch of `select`, which still runs
/// `recordComparison` with the operation under test.
final class CloudVaultOpaqueIdentifierShadowSliceTests: XCTestCase {
    private let shadowEnvironment = ["OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE": "shadow"]

    func testOpaqueIdentifierShadowComparisonsCarryOpaqueIdentifiersSlice() throws {
        let key = Data(repeating: 0x09, count: 32)
        let recorder = ShadowComparisonRecorder()
        DomainCoreShadowComparisonCollector.configure { recorder.append($0) }
        defer { DomainCoreShadowComparisonCollector.configure(nil) }

        // Each operation routes through `select` -> `recordComparison`. The
        // legacy closure returns a deterministic placeholder; shadow mode still
        // records the comparison (with mismatchCategory `native_unavailable` on
        // hosts without the XCFramework) and returns the legacy value.
        _ = try CloudVaultDomainCoreAdapter.projectMemoryDocID(
            slug: "la-hormiga-dormida",
            keyData: key,
            environment: shadowEnvironment,
            legacy: { "legacy-pm" }
        )
        _ = try CloudVaultDomainCoreAdapter.pensieveDedupHash(
            plaintext: "deploy the daemon before midnight",
            keyData: key,
            environment: shadowEnvironment,
            legacy: { "legacy-dedup" }
        )
        _ = try CloudVaultDomainCoreAdapter.pensieveSlugHmac(
            slug: "slug-atlas",
            keyData: key,
            environment: shadowEnvironment,
            legacy: { "legacy-hmac" }
        )
        _ = try CloudVaultDomainCoreAdapter.subscriptionDocID(
            agentURI: "agent://codex/1",
            topicID: "topic-7",
            keyData: key,
            environment: shadowEnvironment,
            legacy: { "legacy-sub" }
        )

        let comparisons = recorder.snapshot()
        let opaqueComparisons = comparisons.filter { $0.domain == "cloudvault" }
        XCTAssertEqual(opaqueComparisons.count, 4, "each opaque-identifier entry point must record exactly one shadow comparison")
        for comparison in opaqueComparisons {
            XCTAssertEqual(
                comparison.slice,
                "opaque-identifiers",
                "operation \(comparison.operation) must carry the opaque-identifiers slice, not foundation"
            )
        }
        // Pin the exact operation set so a dropped or renamed entry point fails loudly.
        XCTAssertEqual(
            Set(opaqueComparisons.map(\.operation)),
            Set([
                "project_memory_doc_id",
                "pensieve_dedup_hash",
                "pensieve_slug_hmac",
                "subscription_doc_id",
            ])
        )
    }
}

/// Thread-safe recorder for the `@Sendable` collector closure configured on
/// `DomainCoreShadowComparisonCollector`. Swift 6 `SendableClosureCaptures`
/// rejects mutating a captured local `var` from a `@Sendable` closure, so the
/// collector appends through this `@unchecked Sendable` NSLock-backed box and
/// the test reads a snapshot back on the main thread.
private final class ShadowComparisonRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DomainCoreShadowComparison] = []

    func append(_ comparison: DomainCoreShadowComparison) {
        lock.lock()
        storage.append(comparison)
        lock.unlock()
    }

    func snapshot() -> [DomainCoreShadowComparison] {
        lock.lock()
        let copy = storage
        lock.unlock()
        return copy
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
    case unexpectedLegacy
    case unknownPurpose
}

private struct Fixture: Decodable {
    let aad: [AAD]
    let sha256: [SHA256]
    let vaultKeyID: [VaultKeyID]
    let keyedHashes: [KeyedHash]
    let expectedSessionBodyHash: [ExpectedSessionBodyHash]
    let aesGcm: [AESGCM]
    let recovery: Recovery
    let p256Escrow: P256Escrow

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

    struct AESGCM: Decodable {
        let keyHex: String
        let nonceHex: String
        let plaintextHex: String
        let aadHex: String
        let ciphertextHex: String
        let tagHex: String
        let combinedBase64: String
    }

    struct Recovery: Decodable {
        let formattedKey: String
        let normalizedKey: String
        let wrappingKeyHex: String
        let verificationHash: String
        let unicodeFormattedKey: String
        let unicodeNormalizedKey: String
        let unicodeWrappingKeyHex: String
        let vaultKeyHex: String
        let nonceHex: String
        let combinedHex: String
    }

    struct P256Escrow: Decodable {
        let ephemeralPublicKeyHex: String
        let sharedSecretHex: String
        let wrappingKeyHex: String
        let nonceHex: String
        let plaintextHex: String
        let wireHex: String
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
