import XCTest
@testable import OpenBurnBar
import OpenBurnBarKernel

/// The grant store is the Wire's consent supply. These pin the two pure
/// surfaces the firestore.rules `warWireGrantWrite` function depends on:
/// canonical pair ordering (the rules reject `bodyIdA >= bodyIdB`) and a
/// fail-closed reader (anything not provably "active" is revoked).
final class WarWireGrantStoreTests: XCTestCase {

    private let bodyA = "relay-host-aaaa"
    private let bodyB = "relay-host-bbbb"

    // MARK: - sortedPair

    func test_sortedPairIsOrderIndependent() {
        let forward = WarWireGrantStore.sortedPair(bodyA, bodyB)
        let reverse = WarWireGrantStore.sortedPair(bodyB, bodyA)
        XCTAssertEqual(forward?.id, reverse?.id)
        XCTAssertEqual(forward?.a, reverse?.a)
        XCTAssertEqual(forward?.b, reverse?.b)
    }

    /// The rules enforce `bodyIdA < bodyIdB` and `pairId == bodyIdA + "__" + bodyIdB`;
    /// a store that wrote unsorted endpoints would be rejected on every grant.
    func test_sortedPairMatchesTheRulesContract() {
        let pair = WarWireGrantStore.sortedPair(bodyB, bodyA)
        XCTAssertEqual(pair?.a, bodyA)
        XCTAssertEqual(pair?.b, bodyB)
        XCTAssertEqual(pair?.id, "\(bodyA)__\(bodyB)")
        XCTAssertEqual(pair?.id, WarWireGrant.pairID(bodyA, bodyB))
    }

    func test_sortedPairTrimsWhitespace() {
        XCTAssertEqual(WarWireGrantStore.sortedPair("  \(bodyA)", "\(bodyB)  ")?.id, "\(bodyA)__\(bodyB)")
    }

    func test_sortedPairRejectsSelfPair() {
        XCTAssertNil(WarWireGrantStore.sortedPair(bodyA, bodyA))
        XCTAssertNil(WarWireGrantStore.sortedPair(bodyA, " \(bodyA) "))
    }

    func test_sortedPairRejectsEmptyEndpoints() {
        XCTAssertNil(WarWireGrantStore.sortedPair("", bodyB))
        XCTAssertNil(WarWireGrantStore.sortedPair(bodyA, "   "))
    }

    // MARK: - grant(from:)

    func test_grantParsesActiveDocument() {
        let grant = WarWireGrantStore.grant(from: [
            "bodyIdA": bodyA,
            "bodyIdB": bodyB,
            "state": "active"
        ])
        XCTAssertEqual(grant, WarWireGrant(bodyIDA: bodyA, bodyIDB: bodyB, state: .active))
    }

    func test_grantParsesRevokedDocument() {
        let grant = WarWireGrantStore.grant(from: [
            "bodyIdA": bodyA,
            "bodyIdB": bodyB,
            "state": "revoked"
        ])
        XCTAssertEqual(grant?.state, .revoked)
    }

    /// Fail-closed: an unknown or missing state must never read as active.
    func test_unknownStateReadsAsRevoked() {
        XCTAssertEqual(
            WarWireGrantStore.grant(from: ["bodyIdA": bodyA, "bodyIdB": bodyB, "state": "pending"])?.state,
            .revoked
        )
        XCTAssertEqual(
            WarWireGrantStore.grant(from: ["bodyIdA": bodyA, "bodyIdB": bodyB])?.state,
            .revoked
        )
    }

    func test_grantRejectsMissingOrEmptyEndpoints() {
        XCTAssertNil(WarWireGrantStore.grant(from: ["bodyIdB": bodyB, "state": "active"]))
        XCTAssertNil(WarWireGrantStore.grant(from: ["bodyIdA": "", "bodyIdB": bodyB, "state": "active"]))
    }

    /// A parsed grant must key on the canonical pair id so lookups from either
    /// machine hit the same entry.
    func test_parsedGrantPairIDIsCanonical() {
        let grant = WarWireGrantStore.grant(from: [
            "bodyIdA": bodyA,
            "bodyIdB": bodyB,
            "state": "active"
        ])
        XCTAssertEqual(grant?.pairID, WarWireGrant.pairID(bodyB, bodyA))
    }

    // MARK: - cache lifecycle (fail closed)

    private var activeDocument: [String: Any] {
        ["bodyIdA": bodyA, "bodyIdB": bodyB, "state": "active"]
    }

    @MainActor
    private func loadedStore() -> WarWireGrantStore {
        let store = WarWireGrantStore(accountManager: FakeAccountManager.makeSignedIn())
        store.apply(documents: [activeDocument], error: nil)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(store.grant(between: bodyA, and: bodyB)?.state, .active)
        return store
    }

    /// A listener error means consent can no longer be verified, and
    /// unverifiable consent reads as revoked: the cached grants must go, not
    /// linger as the last-known answer.
    @MainActor
    func test_listenerErrorClearsCachedGrants() {
        let store = loadedStore()
        store.apply(documents: nil, error: URLError(.notConnectedToInternet))
        XCTAssertFalse(store.hasLoaded)
        XCTAssertNil(store.grant(between: bodyA, and: bodyB))
    }

    /// A recovered listener repopulates the cache on its next snapshot.
    @MainActor
    func test_snapshotAfterErrorRestoresGrants() {
        let store = loadedStore()
        store.apply(documents: nil, error: URLError(.notConnectedToInternet))
        store.apply(documents: [activeDocument], error: nil)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertEqual(store.grant(between: bodyA, and: bodyB)?.state, .active)
    }

    /// A stopped store can no longer verify consent, so it holds none.
    @MainActor
    func test_stopClearsCachedGrants() {
        let store = loadedStore()
        store.stop()
        XCTAssertFalse(store.hasLoaded)
        XCTAssertNil(store.grant(between: bodyA, and: bodyB))
    }
}
