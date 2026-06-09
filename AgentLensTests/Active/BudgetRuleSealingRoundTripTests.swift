import XCTest
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

/// Verifies that budget-rule project names and labels are sealed at rest with the
/// Cloud Vault key and never written as plaintext, while legacy plaintext docs still
/// decode during migration. Exercises the exact `CloudVaultCrypto` primitives that
/// `CloudBudgetService.encodeRule`/`decodeRule` use, so the sealing contract is
/// asserted without standing up a real Firestore instance.
final class BudgetRuleSealingRoundTripTests: XCTestCase {
    private let vaultKey = Data(repeating: 0x42, count: 32)

    // MARK: - Seal → open round trip

    func test_sealedProjectNameAndLabel_roundTripThroughVaultKey() throws {
        let projectName = "Quarterly Roadmap"
        let label = "Engineering Cap"

        var doc: [String: Any] = [:]
        doc["sealedProjectName"] = try CloudVaultCrypto.firestoreDictionary(
            CloudVaultCrypto.sealText(projectName, keyData: vaultKey)
        )
        doc["sealedLabel"] = try CloudVaultCrypto.firestoreDictionary(
            CloudVaultCrypto.sealText(label, keyData: vaultKey)
        )
        if let hash = CloudVaultCrypto.projectKeyHash(for: projectName, keyData: vaultKey) {
            doc["projectKeyHash"] = hash
        }

        // Raw cloud document must carry NO plaintext name or label.
        XCTAssertNil(doc["projectName"])
        XCTAssertNil(doc["label"])
        let serialized = String(describing: doc)
        XCTAssertFalse(serialized.contains(projectName))
        XCTAssertFalse(serialized.contains(label))

        // A key holder recovers the exact values.
        let openedProject = CloudVaultCrypto.openSealedProjectName(from: doc, keyData: vaultKey)
        let openedLabel = CloudVaultCrypto.openSealedProjectName(
            from: doc,
            sealedField: "sealedLabel",
            legacyField: "label",
            keyData: vaultKey
        )
        XCTAssertEqual(openedProject, projectName)
        XCTAssertEqual(openedLabel, label)

        // Opaque group-by hash is a stable 32-hex trapdoor.
        let hash = try XCTUnwrap(doc["projectKeyHash"] as? String)
        XCTAssertEqual(hash.count, 32)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(hash, CloudVaultCrypto.projectKeyHash(for: projectName, keyData: vaultKey))
    }

    // MARK: - Legacy fallback

    func test_legacyPlaintextDoc_stillDecodesWhenSealedFieldAbsent() {
        let legacyDoc: [String: Any] = [
            "projectName": "Legacy Project",
            "label": "Legacy Label"
        ]
        XCTAssertEqual(
            CloudVaultCrypto.openSealedProjectName(from: legacyDoc, keyData: vaultKey),
            "Legacy Project"
        )
        XCTAssertEqual(
            CloudVaultCrypto.openSealedProjectName(
                from: legacyDoc,
                sealedField: "sealedLabel",
                legacyField: "label",
                keyData: vaultKey
            ),
            "Legacy Label"
        )
    }

    func test_sealedDoc_withoutKey_doesNotLeakLegacyValue() throws {
        // A doc that carries BOTH a sealed envelope and (transitionally) a stale
        // plaintext field must never return the plaintext when the key is absent.
        var doc: [String: Any] = [
            "projectName": "Stale Plaintext"
        ]
        doc["sealedProjectName"] = try CloudVaultCrypto.firestoreDictionary(
            CloudVaultCrypto.sealText("Sealed Truth", keyData: vaultKey)
        )

        // No key on this device → sealed but unreadable → nil (not the stale value).
        XCTAssertNil(CloudVaultCrypto.openSealedProjectName(from: doc, keyData: nil))
        // With the key → the sealed value wins.
        XCTAssertEqual(
            CloudVaultCrypto.openSealedProjectName(from: doc, keyData: vaultKey),
            "Sealed Truth"
        )
    }

    func test_emptyProjectName_producesNoGroupByHash() {
        XCTAssertNil(CloudVaultCrypto.projectKeyHash(for: "", keyData: vaultKey))
        XCTAssertNil(CloudVaultCrypto.projectKeyHash(for: "   ", keyData: vaultKey))
    }

    /// The group-by trapdoor MUST normalize identically to the Android writer
    /// (`FirestoreRepository.kt projectKeyHash`) so a project used on Mac/iOS AND
    /// Android lands in ONE bucket. Both collapse to ASCII `[a-z0-9]` only —
    /// stopwords/short tokens are KEPT — so "The API v2" hashes the same as its raw
    /// filtered form "theapiv2" (NOT the stopword-stripped "apiv2" the old
    /// `normalizedTokens().joined()` produced, which diverged from Android).
    func test_projectKeyHash_matchesAndroidAsciiContract() {
        let stopwordName = CloudVaultCrypto.projectKeyHash(for: "The API v2", keyData: vaultKey)
        XCTAssertNotNil(stopwordName)
        XCTAssertEqual(stopwordName, CloudVaultCrypto.projectKeyHash(for: "theapiv2", keyData: vaultKey))
        // Case + punctuation are folded, content is preserved.
        XCTAssertEqual(
            CloudVaultCrypto.projectKeyHash(for: "Mercury Media", keyData: vaultKey),
            CloudVaultCrypto.projectKeyHash(for: "mercury-media", keyData: vaultKey)
        )
    }
}
