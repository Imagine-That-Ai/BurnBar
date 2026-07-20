import Foundation
import OpenBurnBarKernel
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Parser Resource Governance

/// Limits for one governed parse pass. `nil` fields are unenforced.
public struct ParserResourceLimits: Sendable {
    /// Maximum bytes of new (uncached) file content one pass may read.
    public var fileByteBudget: Int64?
    /// Hard abort when process physical footprint crosses this.
    public var memoryCeilingBytes: Int64?
    /// Log a warning (once per pass) when footprint crosses this.
    public var memorySoftLimitBytes: Int64?

    public init(
        fileByteBudget: Int64? = nil,
        memoryCeilingBytes: Int64? = nil,
        memorySoftLimitBytes: Int64? = nil
    ) {
        self.fileByteBudget = fileByteBudget
        self.memoryCeilingBytes = memoryCeilingBytes
        self.memorySoftLimitBytes = memorySoftLimitBytes
    }

    public static let unlimited = ParserResourceLimits()
}

/// Thrown from `ParserResourceGovernor.checkpoint()` when a hard limit is hit.
public enum ParserResourceExceeded: Error, CustomStringConvertible, Equatable {
    case memoryCeiling(footprintBytes: Int64, ceilingBytes: Int64)

    public var description: String {
        switch self {
        case let .memoryCeiling(footprint, ceiling):
            let footprintMB = footprint / (1024 * 1024)
            let ceilingMB = ceiling / (1024 * 1024)
            return "parse aborted: process footprint \(footprintMB)MB crossed the \(ceilingMB)MB ceiling"
        }
    }
}

/// Shared, thread-safe accounting for one parse pass (one governor per pass;
/// all parsers in the pass share it, so the budget bounds the *pass*, not each
/// parser).
public final class ParserResourceGovernor: Sendable {
    private let limits: ParserResourceLimits
    private let footprintProvider: @Sendable () -> Int64
    private let onSoftLimit: (@Sendable (Int64) -> Void)?
    private struct State: Sendable {
        var consumedBytes: Int64 = 0
        var deferredFileCount: Int = 0
        var softLimitReported = false
        var checkpointCounter: UInt64 = 0
    }
    private let state = Locked(State())

    /// - Parameters:
    ///   - footprintProvider: injectable for tests; defaults to the live
    ///     process physical footprint.
    ///   - onSoftLimit: invoked at most once per pass, off-lock, with the
    ///     footprint that crossed the soft limit.
    public init(
        limits: ParserResourceLimits,
        footprintProvider: @escaping @Sendable () -> Int64 = { ParserResourceGovernor.currentPhysicalFootprint() },
        onSoftLimit: (@Sendable (Int64) -> Void)? = nil
    ) {
        self.limits = limits
        self.footprintProvider = footprintProvider
        self.onSoftLimit = onSoftLimit
    }

    /// True when this governor accounts work without imposing any resource cap.
    var isUnlimited: Bool {
        limits.fileByteBudget == nil
            && limits.memoryCeilingBytes == nil
            && limits.memorySoftLimitBytes == nil
    }

    /// Whether a file of `estimatedBytes` of new content may be read in this
    /// pass. Answers `false` (and counts a deferral) once the budget is
    /// exhausted; the caller keeps its cached/estimated values for that file
    /// and retries next pass. Admitted bytes are charged immediately.
    ///
    /// A pass with no `fileByteBudget` admits everything.
    /// The budget is soft at the boundary: the admission that crosses the
    /// budget is allowed (a pass always makes progress even when a single
    /// file exceeds the whole budget).
    public func admitFile(estimatedBytes: Int64) -> Bool {
        state.withLock { state in
            guard let budget = limits.fileByteBudget else {
                state.consumedBytes += estimatedBytes
                return true
            }
            guard state.consumedBytes < budget else {
                state.deferredFileCount += 1
                return false
            }
            state.consumedBytes += estimatedBytes
            return true
        }
    }

    /// Records a file that a bounded adapter cannot safely inspect. This keeps
    /// the caller's checkpoint watermark frozen without charging unread bytes.
    public func recordDeferredFile() {
        state.withLock { state in
            state.deferredFileCount += 1
        }
    }

    /// Memory-ceiling check. Call between files and every few thousand lines
    /// inside per-line loops. Throws when the hard ceiling is crossed.
    public func checkpoint() throws {
        let shouldSample = state.withLock { state in
            state.checkpointCounter += 1
            // Sample the footprint on every 32nd checkpoint — task_info is cheap
            // (~µs) but line loops can run millions of iterations.
            return state.checkpointCounter % 32 == 1
        }
        guard shouldSample else { return }
        guard limits.memoryCeilingBytes != nil || limits.memorySoftLimitBytes != nil else { return }

        let footprint = footprintProvider()
        guard footprint > 0 else { return }

        if let soft = limits.memorySoftLimitBytes, footprint > soft {
            let shouldReport = state.withLock { state in
                guard !state.softLimitReported else { return false }
                state.softLimitReported = true
                return true
            }
            if shouldReport { onSoftLimit?(footprint) }
        }
        if let ceiling = limits.memoryCeilingBytes, footprint > ceiling {
            throw ParserResourceExceeded.memoryCeiling(footprintBytes: footprint, ceilingBytes: ceiling)
        }
    }

    /// Bytes of new file content admitted so far in this pass.
    public var consumedBytes: Int64 {
        state.withLock { $0.consumedBytes }
    }

    /// Files deferred to a later pass because the budget was exhausted.
    public var deferredFileCount: Int {
        state.withLock { $0.deferredFileCount }
    }

    /// Current process physical footprint (the same number Activity Monitor
    /// and `footprint(1)` report). Returns 0 where unavailable.
    public static func currentPhysicalFootprint() -> Int64 {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
        #else
        return 0
        #endif
    }
}
