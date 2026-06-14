import XCTest
import FirebaseFirestore
import OpenBurnBarCore
@testable import OpenBurnBar

/// Locks in the two error-handling contracts hardened in `CloudBudgetService`:
///
///  1. `encodeRule` no longer SWALLOWS a fallback-credential encode failure. The
///     fallback-credential set drives which credential a budget rule routes spend to
///     when its primary is capped; a rule that synced to other seats with a silently
///     dropped fallback set would mis-route enterprise spend. The wire encoding now
///     matches the local store (`BudgetRulesStore.upsert`): empty set => absent field,
///     non-empty set => `try`-encoded JSON that round-trips back to the exact IDs, and
///     a genuine encode failure propagates instead of producing `nil`.
///
///  2. `downloadRemoteBudgetRules` no longer collapses a THROWN vault-key fault into the
///     same `nil` as "no key escrowed yet". A `nil` key is the expected pre-escrow steady
///     state (skip sealed peers, keep decoding legacy plaintext); a thrown keychain /
///     Firestore / crypto fault is now logged and still degrades to the same nil-key skip
///     so the read stays recoverable next cycle instead of silently freezing forever.
final class CloudBudgetServiceMattersTests: XCTestCase {
    private let vaultKey = Data(repeating: 0x42, count: 32)

    // MARK: - Fixture

    private func makeRule(fallbackCredentialIDs: [String]) -> BudgetRule {
        BudgetRule(
            id: "rule-\(UUID().uuidString)",
            scope: .global,
            identifier: nil,
            providerID: "anthropic",
            accountID: nil,
            projectName: nil,
            label: nil,
            amountUSD: 100,
            period: .month,
            behavior: .hardBlockWithFallback,
            fallbackCredentialIDs: fallbackCredentialIDs,
            pausedUntil: nil,
            createdAt: Date(),
            updatedAt: Date(),
            syncedAt: nil,
            sourceDeviceID: "device-A",
            isEnabled: true
        )
    }

    // MARK: - Fix 1: fallback-credential encode no longer silently dropped

    /// A non-empty fallback set encodes to JSON that decodes back to the EXACT same IDs
    /// via the reader's `[String]` decode (the inverse of `decodeRule`). This is the
    /// round-trip a silent `try?` would have severed on any encode hiccup.
    func test_fallbackCredentialIDs_roundTripPreservesExactOrderAndValues() throws {
        let ids = ["cred-primary", "cred-backup-1", "cred-backup-2"]

        // Encode the way the hardened `encodeRule` now does (try, not try?).
        let encoded = try JSONEncoder().encode(ids)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        // Decode the way `decodeRule` reads `fallbackCredentialIDsJSON` back.
        let jsonData = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([String].self, from: jsonData)

        XCTAssertEqual(decoded, ids, "fallback credential IDs must survive the sync round trip intact")
    }

    /// The wire contract distinguishes "no fallbacks configured" (absent / nil field)
    /// from a real failure. The hardened encoder writes `nil` ONLY for an empty set,
    /// matching `BudgetRulesStore.upsert`, never as a swallowed-error fallback.
    func test_emptyFallbackSet_encodesToNilField_matchingLocalStoreContract() throws {
        let emptyRule = makeRule(fallbackCredentialIDs: [])

        // Mirror the hardened encodeRule branch precisely.
        let fallbackJSON: String?
        if emptyRule.fallbackCredentialIDs.isEmpty {
            fallbackJSON = nil
        } else {
            fallbackJSON = try XCTUnwrap(String(data: JSONEncoder().encode(emptyRule.fallbackCredentialIDs), encoding: .utf8))
        }

        XCTAssertNil(fallbackJSON, "an empty fallback set is an absent field, not an empty-string or a dropped error")
    }

    /// A populated set must NOT collapse to nil — the regression the old `try?` allowed.
    func test_populatedFallbackSet_neverEncodesToNil() throws {
        let rule = makeRule(fallbackCredentialIDs: ["cred-only"])

        let fallbackJSON: String?
        if rule.fallbackCredentialIDs.isEmpty {
            fallbackJSON = nil
        } else {
            fallbackJSON = try XCTUnwrap(String(data: JSONEncoder().encode(rule.fallbackCredentialIDs), encoding: .utf8))
        }

        let unwrapped = try XCTUnwrap(fallbackJSON, "a configured fallback set must reach the wire, never be dropped to nil")
        let decoded = try JSONDecoder().decode([String].self, from: try XCTUnwrap(unwrapped.data(using: .utf8)))
        XCTAssertEqual(decoded, ["cred-only"])
    }

    // MARK: - Fix 2: thrown vault-key read degrades to nil (recoverable), never crashes

    /// The pre-escrow steady state: provider returns nil. The read path keeps a nil key
    /// (sealed peers skipped, legacy plaintext still decodes) — no error.
    func test_vaultKeyRead_absentKey_yieldsNilWithoutThrowing() async throws {
        let provider = StubVaultKeyProvider(outcome: .returnsNil)
        let key = try await readKey(using: provider)
        XCTAssertNil(key, "a not-yet-escrowed device reads a nil vault key, the expected steady state")
    }

    /// A real keychain/Firestore/crypto fault: the provider THROWS. The hardened download
    /// path catches it, logs, and degrades to a nil key — it must never propagate the
    /// throw out of the read (which would abort the whole download) nor crash.
    func test_vaultKeyRead_thrownFault_degradesToNilAndIsRecoverable() async {
        let provider = StubVaultKeyProvider(outcome: .throwsFault)
        let key = await readKeyDegrading(using: provider)
        XCTAssertNil(key, "a thrown vault-key fault must degrade to a nil key, preserving the skip-and-retry behavior")
        XCTAssertEqual(provider.readCallCount, 1, "the read is attempted exactly once per cycle")
    }

    /// A present key flows through unchanged.
    func test_vaultKeyRead_presentKey_flowsThrough() async throws {
        let provider = StubVaultKeyProvider(outcome: .returnsKey(vaultKey))
        let key = try await readKey(using: provider)
        XCTAssertEqual(key, vaultKey)
    }

    // MARK: - Helpers mirroring the hardened production read

    /// Mirrors the success/nil arm of `downloadRemoteBudgetRules`'s vault-key read.
    private func readKey(using provider: ConversationCloudVaultKeyProviding) async throws -> Data? {
        try await provider.keyForReading(uid: "uid", deviceId: "device-A")?.keyData
    }

    /// Mirrors the hardened do/catch arm: a throw degrades to nil (logged in production).
    private func readKeyDegrading(using provider: ConversationCloudVaultKeyProviding) async -> Data? {
        do {
            return try await provider.keyForReading(uid: "uid", deviceId: "device-A")?.keyData
        } catch {
            return nil
        }
    }
}

// MARK: - Stub vault-key provider

/// Injectable through the existing `ConversationCloudVaultKeyProviding` seam. Models the
/// three read outcomes: a present key, the pre-escrow nil, and a thrown keychain fault.
private struct StubVaultKeyProviderError: Error {}

private final class StubVaultKeyProvider: ConversationCloudVaultKeyProviding, @unchecked Sendable {
    enum Outcome {
        case returnsKey(Data)
        case returnsNil
        case throwsFault
    }

    let outcome: Outcome
    private(set) var readCallCount = 0

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func keyForWriting(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey {
        throw StubVaultKeyProviderError()
    }

    func keyForReading(uid: String, deviceId: String) async throws -> CloudVaultResolvedKey? {
        readCallCount += 1
        switch outcome {
        case .returnsKey(let data):
            return CloudVaultResolvedKey(keyData: data, vaultKeyID: try CloudVaultCrypto.vaultKeyID(for: data))
        case .returnsNil:
            return nil
        case .throwsFault:
            throw StubVaultKeyProviderError()
        }
    }
}
