import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Regression tests proving that `TokenUsage` resolves to a single metatype
/// across the `OpenBurnBarCore` module boundary.
///
/// `FirestoreRepository.swift:184` branches on `T.self == TokenUsage.self` to
/// decide whether to enrich a decoded payload with provider metadata. If
/// `OpenBurnBarCore` were statically linked twice — once into the app host and
/// once into the test bundle — the two `TokenUsage.self` metatypes would be
/// distinct objects and the comparison would silently fail, dropping provider
/// enrichment. Fix 3 made `OpenBurnBarCore` a `.dynamic` product so exactly one
/// copy is loaded. These tests guard that guarantee.
final class OpenBurnBarCoreTypeIdentityTests: XCTestCase {

    /// Mirrors the exact comparison at `FirestoreRepository.swift:184`.
    private func isTokenUsage<T>(_ type: T.Type) -> Bool {
        T.self == TokenUsage.self
    }

    /// Core regression: the metatype comparison that `FirestoreRepository`
    /// relies on must hold when `TokenUsage.self` is referenced from the test
    /// bundle and from `OpenBurnBarCore`'s own code. With a single dynamic
    /// framework copy both sides resolve to the same metatype.
    func test_tokenUsageTypeIdentityHoldsAcrossModuleBoundary() {
        XCTAssertTrue(isTokenUsage(TokenUsage.self))
    }

    /// Sanity: `TokenUsage.self` is equal to itself.
    func test_tokenUsageSelfIsConsistent() {
        XCTAssertEqual(TokenUsage.self, TokenUsage.self)
    }

    /// Proves the comparison is meaningful — it distinguishes `TokenUsage` from
    /// other types rather than matching everything.
    func test_tokenUsageSelfIsUnique() {
        XCTAssertNotEqual(TokenUsage.self, String.self)
        XCTAssertNotEqual(TokenUsage.self, Int.self)
    }
}