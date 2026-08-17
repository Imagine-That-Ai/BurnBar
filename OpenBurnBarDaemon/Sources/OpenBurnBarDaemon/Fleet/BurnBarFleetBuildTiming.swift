import Foundation

/// Build timing delivered to the test-only snapshot-builder hook.
///
/// The hook is intentionally internal: production callers cannot install
/// instrumentation, while `@testable import BurnBarDaemon` can measure the
/// builder's own start-to-end interval without routing through RPC or the
/// persistence layer.
struct BurnBarFleetBuildTiming: Sendable {
    let startedAtNanoseconds: UInt64
    let endedAtNanoseconds: UInt64

    var elapsedNanoseconds: UInt64 {
        endedAtNanoseconds >= startedAtNanoseconds
            ? endedAtNanoseconds - startedAtNanoseconds
            : 0
    }

    var elapsedMilliseconds: Double {
        Double(elapsedNanoseconds) / 1_000_000.0
    }
}

/// Test-only hook type for direct `BurnBarFleetSnapshotBuilder.build()`
/// measurements. The callback runs synchronously after the build completes,
/// including when a build throws.
typealias BurnBarFleetBuildTimingHook = @Sendable (BurnBarFleetBuildTiming) -> Void
