import Foundation
import XCTest
@testable import OpenBurnBarKernel

/// Package-level behavior gate for `CloudVaultKeyStore.deleteKey(uid:)` — the
/// destructor the team key ring calls to burn a PENDING generation the roster
/// authority refused (`abandonTeamKeyGeneration`, memory program D16 / P21).
///
/// The Keychain is real here, not faked: `CloudVaultKeyStore` reaches
/// `SecItemDelete` directly, so a fake would gate nothing that ships. Isolation
/// comes from the store's own `service:` seam — every case mints a service name
/// unique to this process, so the cases never see each other's items and never
/// touch the product service (`com.openburnbar.cloud-vault`) on a developer's
/// login keychain. `tearDown` removes every account any case created, including
/// the ones a failed assertion left behind.
final class CloudVaultKeyStoreDeleteKeyTests: XCTestCase {
    private var services: [String] = []
    private var accounts: [String] = []

    override func tearDown() {
        for service in services {
            let store = CloudVaultKeyStore(service: service)
            for uid in accounts {
                try? store.deleteKey(uid: uid)
            }
        }
        services = []
        accounts = []
        super.tearDown()
    }

    /// A store bound to a service name no other test (or the product) uses.
    private func makeIsolatedStore() -> CloudVaultKeyStore {
        let service = "com.openburnbar.tests.cloud-vault-key-store.\(UUID().uuidString)"
        services.append(service)
        return CloudVaultKeyStore(service: service)
    }

    private func makeUID() -> String {
        let uid = "uid-\(UUID().uuidString)"
        accounts.append(uid)
        return uid
    }

    /// The success status path: the item exists, `SecItemDelete` returns
    /// `errSecSuccess`, and the key is gone rather than merely shadowed.
    func test_deleteKey_removesTheStoredKeySoTheNextLoadIsNil() throws {
        let store = makeIsolatedStore()
        let uid = makeUID()
        let key = Data(repeating: 0x5A, count: 32)

        try store.saveKey(key, uid: uid)
        XCTAssertEqual(try store.loadKey(uid: uid), key)

        try store.deleteKey(uid: uid)

        XCTAssertNil(try store.loadKey(uid: uid))
    }

    /// The `errSecItemNotFound` arm of the guard: deleting a key that was never
    /// written leaves exactly the state the caller asked for, so it must not
    /// throw. Deleting twice must not throw either — the documented idempotent
    /// retry the abandon path depends on when a callable is replayed.
    func test_deleteKey_onAnAbsentAccountSucceedsAsAnIdempotentRetry() throws {
        let store = makeIsolatedStore()
        let neverWritten = makeUID()

        XCTAssertNoThrow(try store.deleteKey(uid: neverWritten))

        let uid = makeUID()
        try store.saveKey(Data(repeating: 0x11, count: 32), uid: uid)
        try store.deleteKey(uid: uid)

        XCTAssertNoThrow(try store.deleteKey(uid: uid))
        XCTAssertNil(try store.loadKey(uid: uid))
    }

    /// The query is pinned to `account(uid:)`, so a delete must destroy one
    /// generation and not the ring around it. A `deleteKey` that dropped the
    /// account predicate would take every retained team key version with it and
    /// leave the joiner unable to open older facts.
    func test_deleteKey_removesOnlyTheNamedAccountInTheSameService() throws {
        let store = makeIsolatedStore()
        let doomed = makeUID()
        let survivor = makeUID()
        let survivorKey = Data(repeating: 0x2C, count: 32)

        try store.saveKey(Data(repeating: 0x1B, count: 32), uid: doomed)
        try store.saveKey(survivorKey, uid: survivor)

        try store.deleteKey(uid: doomed)

        XCTAssertNil(try store.loadKey(uid: doomed))
        XCTAssertEqual(try store.loadKey(uid: survivor), survivorKey)
    }

    /// The query is pinned to `service` too. Two stores holding the same uid are
    /// two different keychains as far as this API is concerned — the team ring
    /// and the personal vault must not be able to delete through each other.
    func test_deleteKey_isScopedToItsOwnServiceAndSparesOtherStores() throws {
        let teamStore = makeIsolatedStore()
        let personalStore = makeIsolatedStore()
        let uid = makeUID()
        let personalKey = Data(repeating: 0x3D, count: 32)

        try teamStore.saveKey(Data(repeating: 0x4E, count: 32), uid: uid)
        try personalStore.saveKey(personalKey, uid: uid)

        try teamStore.deleteKey(uid: uid)

        XCTAssertNil(try teamStore.loadKey(uid: uid))
        XCTAssertEqual(try personalStore.loadKey(uid: uid), personalKey)
    }

    /// After a burn the slot is genuinely free: `getOrCreateKey` mints fresh
    /// bytes instead of resurrecting the abandoned generation. A `deleteKey`
    /// that only unlinked a lookup index would fail this.
    func test_deleteKey_freesTheSlotSoGetOrCreateMintsFreshBytes() throws {
        let store = makeIsolatedStore()
        let uid = makeUID()
        let abandoned = Data(repeating: 0x6F, count: 32)

        try store.saveKey(abandoned, uid: uid)
        try store.deleteKey(uid: uid)

        let minted = try store.getOrCreateKey(uid: uid)

        XCTAssertEqual(minted.count, 32)
        XCTAssertNotEqual(minted, abandoned)
        XCTAssertEqual(try store.loadKey(uid: uid), minted)
    }
}
