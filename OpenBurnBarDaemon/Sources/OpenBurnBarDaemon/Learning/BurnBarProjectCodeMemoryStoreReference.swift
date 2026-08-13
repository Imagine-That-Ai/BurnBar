import Foundation

// AUDIT: The reference is a lock-protected mutable slot; callers receive the
// current store only through the synchronization boundary.
// sendable-allowlist: internal-lock-snapshot-store
/// Thread-safe indirection between the daemon's lazy code-memory bootstrap and
/// the long-lived Safari learning coordinator.
///
/// `LearningCoordinator` is constructed before the configured SQLite database
/// necessarily exists. The chat store may create that database later, at which
/// point `BurnBarDaemonServer` bootstraps the canonical
/// `BurnBarProjectCodeMemoryStore`. Keeping one lock-protected reference lets
/// learning reuse that exact store without creating a parallel persistence
/// authority or capturing the server actor from a `@Sendable` closure.
final class BurnBarProjectCodeMemoryStoreReference: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: BurnBarProjectCodeMemoryStore?

    init(_ storage: BurnBarProjectCodeMemoryStore? = nil) {
        self.storage = storage
    }

    func update(_ storage: BurnBarProjectCodeMemoryStore?) {
        lock.lock()
        self.storage = storage
        lock.unlock()
    }

    func current() -> BurnBarProjectCodeMemoryStore? {
        lock.lock()
        let current = storage
        lock.unlock()
        return current
    }
}
