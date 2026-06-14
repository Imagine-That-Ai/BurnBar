import Foundation
import os

// MARK: - Locked<T>

/// A small Sendable box around mutable state protected by an unfair lock.
///
/// Backed by `OSAllocatedUnfairLock` (available macOS 13+ / iOS 16+, comfortably
/// below this target's macOS 14 / iOS 17 floor), which is itself `Sendable`. The
/// lock fully mediates access to the boxed value, so `Locked` conforms to plain
/// `Sendable` — the compiler can verify the box is concurrency-safe without an
/// `@unchecked` escape hatch.
///
/// `Locked` is reference-typed so that in-place mutation is visible to all
/// owners of the box, similar to a `class`-based container.
public final class Locked<T: Sendable>: Sendable {
    private let storage: OSAllocatedUnfairLock<T>

    public init(_ value: T) {
        storage = OSAllocatedUnfairLock(initialState: value)
    }

    public func withLock<R>(_ action: (inout T) throws -> R) rethrows -> R {
        try storage.withLockUnchecked(action)
    }

    public func read() -> T { withLock { $0 } }

    public func write(_ newValue: T) {
        withLock { $0 = newValue }
    }
}

// MARK: - NSLock Extensions

extension NSLock {
    public func withLock<R>(_ work: () -> R) -> R {
        lock()
        defer { unlock() }
        return work()
    }
}

extension NSRecursiveLock {
    public func withLock<R>(_ work: () -> R) -> R {
        lock()
        defer { unlock() }
        return work()
    }
}
