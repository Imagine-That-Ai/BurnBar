import Foundation
import OpenBurnBarKernel

// MARK: - Switcher active-profile writer (Wave 2.1c-v single-writer cutover)
//
// The daemon owns `switcher_active_profile` (ADR-005). The app finalizes its
// active-profile writes locally — the per-provider mirror lookup and the
// fallback selection are computed against its local reads of the app-owned
// `switcher_profiles` table — and commits them through this seam instead of
// writing the table directly. Reads stay on the app's local connection until
// the read cutover.

/// The single commit choke point for app-originated active-profile writes.
/// One RPC per call; the daemon applies each call atomically.
///
/// Sync by design: the switcher setters are synchronous (`throws`, called
/// from ~20 UI call sites and a sync protocol), and the underlying socket
/// call is a bounded blocking round trip (per-call connection, IO timeouts
/// configured) over a local Unix socket with a tiny payload. The pre-cutover
/// path blocked the same thread on a GRDB write to the same file, so the
/// failure and latency posture is unchanged — only the writer moved.
protocol SwitcherActiveProfileWriter: Sendable {
    func apply(
        _ request: BurnBarSwitcherActiveProfileApplyRequest
    ) throws -> BurnBarSwitcherActiveProfileApplyResponse
}

/// Shipping writer: one daemon RPC per call over the control socket. Fails
/// closed when the daemon is unreachable — there is deliberately no
/// local-write fallback (single writer).
struct DaemonSwitcherActiveProfileWriter: SwitcherActiveProfileWriter {
    func apply(
        _ request: BurnBarSwitcherActiveProfileApplyRequest
    ) throws -> BurnBarSwitcherActiveProfileApplyResponse {
        try OpenBurnBarDaemonSocketClient.switcherActiveProfileApply(
            request,
            at: OpenBurnBarDaemonRuntimePaths.live().socketURL
        )
    }
}
