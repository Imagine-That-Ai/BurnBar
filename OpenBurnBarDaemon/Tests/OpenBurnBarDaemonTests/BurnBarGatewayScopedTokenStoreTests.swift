@testable import OpenBurnBarDaemon
import XCTest

/// The Python memory engine never holds a provider key; it receives a
/// short-lived bearer scoped to `memory-*` purposes from the policy courier.
final class BurnBarGatewayScopedTokenStoreTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func test_mintReturnsAHexTokenThatExpiresAfterTheTTL() async {
        let store = BurnBarGatewayScopedTokenStore(now: { self.base }, ttl: 900)
        let minted = await store.mint(purposes: ["memory-extract", "memory-embed"])
        XCTAssertEqual(minted.token.count, 64)
        XCTAssertNotNil(UInt64(minted.token.prefix(16), radix: 16))
        XCTAssertEqual(minted.expiresAt, base.addingTimeInterval(900))
    }

    func test_validateHonorsPurposeScopeAndExpiry() async {
        let store = BurnBarGatewayScopedTokenStore(now: { self.base }, ttl: 900)
        let minted = await store.mint(purposes: ["memory-extract"])
        let valid = await store.validate(token: minted.token, purpose: "memory-extract", now: base.addingTimeInterval(10))
        let wrongPurpose = await store.validate(token: minted.token, purpose: "memory-answer", now: base.addingTimeInterval(10))
        let expired = await store.validate(token: minted.token, purpose: "memory-extract", now: base.addingTimeInterval(901))
        let unknown = await store.validate(token: String(repeating: "0", count: 64), purpose: "memory-extract", now: base)
        XCTAssertTrue(valid)
        XCTAssertFalse(wrongPurpose)
        XCTAssertFalse(expired)
        XCTAssertFalse(unknown)
    }

    func test_twoMintsDifferAndExpiredEntriesArePruned() async {
        let store = BurnBarGatewayScopedTokenStore(now: { self.base }, ttl: 60)
        let first = await store.mint(purposes: ["memory-judge"])
        let second = await store.mint(purposes: ["memory-judge"])
        XCTAssertNotEqual(first.token, second.token)
        _ = await store.validate(token: second.token, purpose: "memory-judge", now: base.addingTimeInterval(120))
        let count = await store.liveTokenCount(now: base.addingTimeInterval(120))
        XCTAssertEqual(count, 0)
    }
}
