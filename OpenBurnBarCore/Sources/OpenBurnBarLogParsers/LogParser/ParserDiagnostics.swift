import Foundation
import OpenBurnBarKernel

// MARK: - Parser diagnostics shim (Windows-buildable, Foundation-only)
//
// Windows-port Phase-2 (G2 parser lift, `docs/WINDOWS_PORT_MASTER_PLAN.md`).
//
// The lifted parsers + disk-cache infra used to log best-effort failures through
// the macOS app's `AppLogger`, which imports `Sentry` + `OSLog` — neither of which
// is part of the Foundation-only Engine subset that compiles off-Apple. Rather than
// drag those into `OpenBurnBarCore`, the parser layer records diagnostics through
// this tiny seam: a settable sink that is a **no-op by default** and can be pointed
// at `AppLogger` (or any logger) by the host app at startup.
//
// This is diagnostic-only — it never influences parser OUTPUT (token/cost/model/
// session), so the G2 byte-identical contract is unaffected whether or not a sink
// is installed. The default no-op keeps the Engine build free of any Apple-only or
// third-party logging dependency.
enum ParserDiagnostics {
    /// A best-effort diagnostic emitted by the parser/cache layer.
    struct Event: Sendable {
        let message: String
        let error: Error?
        init(message: String, error: Error?) {
            self.message = message
            self.error = error
        }
    }

    private static let sink = Locked<(@Sendable (Event) -> Void)?>(nil)

    /// Install a diagnostic sink (e.g. one that forwards to the app's `AppLogger`).
    /// Defaults to `nil` (no-op), which is what the Engine + CI harness use.
    static func installSink(_ handler: (@Sendable (Event) -> Void)?) {
        sink.withLock { $0 = handler }
    }

    /// Record a best-effort silent failure. Routed to the installed sink if any,
    /// otherwise discarded. Never throws, never affects parser output.
    static func silentFailure(_ message: String, error: Error? = nil) {
        let handler = sink.withLock { $0 }
        handler?(Event(message: message, error: error))
    }
}
