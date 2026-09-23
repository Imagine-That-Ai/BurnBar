import Foundation
import OpenBurnBarKernel

// MARK: - Search index writer (Wave 2.1c-iv single-writer cutover)
//
// The daemon owns the search tables (ADR-005). The app finalizes its
// search-index write sets locally — document upserts, chunk diffs
// computed against local reads, replacement sets — and commits them
// through this seam instead of writing the tables directly. Reads stay
// on the app's local connection until the read cutover.

/// The single commit choke point for app-originated search-index
/// writes. One RPC per mutation batch; the daemon applies each batch
/// atomically and assigns only the FTS `rowid` mapping.
protocol SearchIndexWriter: Sendable {
    func apply(_ request: BurnBarSearchIndexApplyRequest) async throws -> BurnBarSearchIndexApplyResponse
}

/// Shipping writer: one daemon RPC per call over the control socket, off
/// the calling executor because the socket round trip is a blocking read
/// (the house `daemonRPC` shape). Fails closed when the daemon is
/// unreachable — there is deliberately no local-write fallback (single
/// writer).
struct DaemonSearchIndexWriter: SearchIndexWriter {
    func apply(_ request: BurnBarSearchIndexApplyRequest) async throws -> BurnBarSearchIndexApplyResponse {
        try await Task.detached(priority: .userInitiated) {
            try OpenBurnBarDaemonSocketClient.searchIndexApply(
                request,
                at: OpenBurnBarDaemonRuntimePaths.live().socketURL
            )
        }.value
    }
}
