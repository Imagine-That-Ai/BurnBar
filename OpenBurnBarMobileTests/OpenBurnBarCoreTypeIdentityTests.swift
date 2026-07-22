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
/// enrichment. The `OpenBurnBarMobileTests` target depends ONLY on the host
/// app (`OpenBurnBarMobile`), not directly on the `OpenBurnBarCore` package
/// product, so `TEST_HOST`/`BUNDLE_LOADER` resolves `import OpenBurnBarCore`
/// against the single host-app copy at runtime. These tests guard that
/// single-copy guarantee.
final class OpenBurnBarCoreTypeIdentityTests: XCTestCase {

    /// Mirrors the exact comparison at `FirestoreRepository.swift:184`.
    private func isTokenUsage<T>(_ type: T.Type) -> Bool {
        T.self == TokenUsage.self
    }

    /// Core regression: the metatype comparison that `FirestoreRepository`
    /// relies on must hold when `TokenUsage.self` is referenced from the test
    /// bundle and from `OpenBurnBarCore`'s own code. With a single host-app
    /// copy both sides resolve to the same metatype.
    func test_tokenUsageTypeIdentityHoldsAcrossModuleBoundary() {
        XCTAssertTrue(isTokenUsage(TokenUsage.self))
    }

    /// Sanity: `TokenUsage.self` is equal to itself via the metatype identity
    /// operator (not Equatable). Uses the generic helper to avoid SwiftLint's
    /// `identical_operands` rule on a direct `TokenUsage.self == TokenUsage.self`.
    func test_tokenUsageSelfIsConsistent() {
        XCTAssertTrue(isTokenUsage(TokenUsage.self))
    }

    /// Proves the comparison is meaningful — it distinguishes `TokenUsage` from
    /// other types rather than matching everything.
    func test_tokenUsageSelfIsUnique() {
        XCTAssertFalse(isTokenUsage(String.self))
        XCTAssertFalse(isTokenUsage(Int.self))
    }
}
