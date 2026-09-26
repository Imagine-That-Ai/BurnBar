import Foundation
import OpenBurnBarKernel

// MARK: - Memory authority writer (Wave 2.1c-iii single-writer cutover)
//
// The daemon owns the memory authority tables (ADR-005). The app finalizes
// its memory write sets locally — the G7 gate, dedup election, reseal
// rules, and tombstone policy all stay app-side — and commits them through
// this seam instead of writing the tables directly. Reads stay on the app's
// local connection until the read cutover.

/// The single commit choke point for app-originated memory authority
/// writes. One RPC per mutation; the daemon applies the operations
/// atomically and assigns only the audit chain fields.
protocol MemoryAuthorityWriter: Sendable {
    func apply(_ request: BurnBarMemoryAuthorityApplyRequest) async throws -> BurnBarMemoryAuthorityApplyResponse
}

/// Shipping writer: one daemon RPC per call over the control socket, off the
/// calling executor because the socket round trip is a blocking read (the
/// house `daemonRPC` shape). Fails closed when the daemon is unreachable —
/// there is deliberately no local-write fallback (single writer). A
/// `rpcConflict` means the reseal precondition moved and nothing was
/// applied; the caller re-reads and retries.
struct DaemonMemoryAuthorityWriter: MemoryAuthorityWriter {
    func apply(_ request: BurnBarMemoryAuthorityApplyRequest) async throws -> BurnBarMemoryAuthorityApplyResponse {
        try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.memoryAuthorityApply(
                request,
                at: OpenBurnBarDaemonRuntimePaths.live().socketURL
            )
        }.value
    }
}
