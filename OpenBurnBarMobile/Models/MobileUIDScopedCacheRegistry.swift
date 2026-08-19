import Foundation

/// Stores register a clearer so an account switch cannot keep the previous UID's
/// in-memory snapshots. Fail-closed: missing registration still requires
/// `MobileAuthSessionPolicy.shouldServeCachedData`.
@MainActor
final class MobileUIDScopedCacheRegistry {
    static let shared = MobileUIDScopedCacheRegistry()

    private var clearers: [() -> Void] = []

    init() {}

    func register(_ clearer: @escaping () -> Void) {
        clearers.append(clearer)
    }

    func clearAll() {
        for clearer in clearers { clearer() }
    }
}
