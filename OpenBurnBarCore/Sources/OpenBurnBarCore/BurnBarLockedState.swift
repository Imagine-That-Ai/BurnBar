import Foundation

// MARK: - Locked<T>

/// A small sendable box around mutable state protected by `NSLock`.
///
/// macOS 14 deployment target precludes `OSAllocatedUnfairLock`, so this
/// uses `NSLock` with a `Sendable` conformance for use in concurrent contexts.
///
/// `Locked` is reference-typed so that in-place mutation is visible to all
/// owners of the box, similar to a `class`-based container.
// Thread safety guaranteed by NSLock; the compiler cannot verify lock-based invariants.
public final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    public init(_ value: T) {
        self._value = value
    }

    public func withLock<R>(_ action: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return action(&_value)
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
