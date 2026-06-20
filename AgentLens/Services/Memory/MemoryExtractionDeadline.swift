import Foundation

// MARK: - Throwing deadline
//
// Races an async operation against a wall-clock deadline. If the operation finishes
// first, the timer child is cancelled and its result is returned. If the deadline
// fires first, the operation child is cancelled and `MemoryExtractionDeadlineError`
// is thrown.
//
// This is the mechanism behind PR-D1 must-fix #5: bounding total extractor wall-clock
// strictly below the 15-min job lease so an in-flight extraction can never outlive its
// lease and be reclaimed + double-processed by a concurrent drain. Cooperative
// cancellation is best-effort — the URLSession calls inside the extractor honor
// `Task.isCancelled` between provider attempts and carry their own per-request
// timeouts, so the deadline is a hard backstop, not the only bound.

/// Thrown when an operation exceeds its wall-clock deadline.
struct MemoryExtractionDeadlineError: Error, Equatable {
    let seconds: TimeInterval
}

/// Run `operation`, throwing `MemoryExtractionDeadlineError` if it does not complete
/// within `seconds`. A non-positive deadline runs the operation without a timer.
func withThrowingDeadline<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard seconds > 0 else { return try await operation() }

    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw MemoryExtractionDeadlineError(seconds: seconds)
        }

        // The first child to finish wins; cancel the loser (the timer if the
        // operation won, or the operation if the deadline fired).
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw MemoryExtractionDeadlineError(seconds: seconds)
        }
        return result
    }
}
