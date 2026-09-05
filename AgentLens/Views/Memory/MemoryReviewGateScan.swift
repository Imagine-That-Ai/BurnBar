import Foundation
import OpenBurnBarKernel

/// Re-scans an already-opened review-inbox body and names which gate WOULD fire
/// on it.
///
/// **A fresh scan, not a recorded decision.** Nothing in this app can ever fill
/// in "which gate quarantined this row": every app-side gate DROPS a candidate
/// (`ControlPlaneStore+MemoryExtractionWorker`, `UsageMemoryCandidateGate`) and
/// `quarantined` is the DDL default review state, so an app quarantine has no
/// firing gate to name. Stamping a `verdict` on such a row would assert a
/// decision no gate ever made. The engine answered the same question the same
/// way — `server.py`'s `_scan_for_a_firing_gate` re-scans and reports
/// `scanGate` / `scanReason` rather than a verdict — and this is the app half of
/// that idea, over the shared `MemorySecretPIIGate`.
///
/// **Ordering** mirrors the engine's `gate.diagnose_firing_gate`: secret shapes
/// first, then everything else the local scanner can actually see. The engine's
/// second and third branches (prompt-injection sentinels, auxiliary-field
/// overflow/injection) have NO Swift detector — `MemorySecretPIIGate` compiles a
/// secret/PII corpus and nothing else — so this never names them. Naming a gate
/// this process cannot run is the same fabrication the whole surface exists to
/// avoid. PII findings, which the Swift gate CAN see and the Python gate has no
/// branch for, get their own honest name rather than being reported as secrets.
enum MemoryReviewGateScan {

    /// What a re-scan of one already-opened body concluded.
    enum GateState: Equatable, Sendable {
        /// The scanner ran and found nothing. The row is here because quarantine
        /// is where every new memory waits, not because a gate fired.
        case noGateFired
        /// The scanner would flag this body. `gate` and `reason` are the scan's,
        /// never a stored verdict.
        case scanned(gate: String, reason: String)
        /// The scan could not run — the fail-closed corpus is missing, or the
        /// sealed body could not be opened — so this row was NOT re-checked and
        /// says so instead of rendering as clean.
        case scannerUnavailable
    }

    /// The gate name for a secret-shape hit. Matches `gate.diagnose_firing_gate`.
    static let secretGate = "secret"
    /// The gate name for a PII hit. The Swift corpus scans for PII as well as
    /// secrets; the Python gate has no such branch, so this name is local.
    static let personalInformationGate = "pii"

    /// Re-scan `body` with the shared fail-closed gate.
    static func scan(_ body: String) -> GateState {
        scan(body) { MemorySecretPIIGate.evaluate($0, policy: .reject) }
    }

    /// Seam-taking overload: the mapping from a gate verdict to a scan line is
    /// the part worth testing, and an unavailable corpus is process-wide state a
    /// test cannot toggle.
    static func scan(_ body: String, evaluate: (String) -> MemoryGateVerdict) -> GateState {
        guard body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return .noGateFired
        }

        let findings = evaluate(body).findings
        guard findings.isEmpty == false else { return .noGateFired }

        // Fail-closed corpus: the gate rejects EVERYTHING with this one
        // synthetic finding, so a row that carries it was never really scanned.
        if findings.contains(where: { $0.id == MemorySecretPIIGate.corpusUnavailableFindingID }) {
            return .scannerUnavailable
        }

        let secrets = findings.filter { $0.kind == .secret }
        if secrets.isEmpty == false {
            return .scanned(gate: secretGate, reason: "secret shape detected: \(dedupedLabels(secrets))")
        }

        let personal = findings.filter { $0.kind == .pii }
        if personal.isEmpty == false {
            return .scanned(
                gate: personalInformationGate,
                reason: "personal information detected: \(dedupedLabels(personal))"
            )
        }

        return .noGateFired
    }

    private static func dedupedLabels(_ findings: [MemoryGateFinding]) -> String {
        var seen = Set<String>()
        return findings
            .compactMap { seen.insert($0.label).inserted ? $0.label : nil }
            .joined(separator: ", ")
    }
}
