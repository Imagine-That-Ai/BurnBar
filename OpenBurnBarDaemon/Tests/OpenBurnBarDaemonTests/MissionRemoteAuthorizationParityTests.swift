import XCTest
import OpenBurnBarKernel
@testable import OpenBurnBarDaemon

/// Split-brain Phase M4 — THE MERGE GATE.
///
/// Before M4 flips the daemon into the SOLE mission-authorization authority and
/// deletes the GUI's own decision code, this test proves the two authorities
/// agreed. It runs ONE input table
/// (trust state × approval mode × approval status × commands/fileEdits ×
/// backend/runtime × fan-out count × entitlement cap) through BOTH:
///
///   1. A pure reference reducer that reconstructs the pre-M4 GUI decision from
///      the surviving shared policy pieces:
///        • `InsightMissionApprovalPolicy.requiresPreDispatchApproval` — the
///          shared approval policy the GUI called verbatim (kept), and
///        • the GUI's per-backend Mac CLI-assistant consent, which required
///          consent for EVERY resolved backend except Hermes. M4 forwards the
///          RESOLVED backend runtime to the daemon, so "runtime != hermes ⇒
///          consent" reproduces the GUI's `requiresMacCLIAssistantConsentForRemoteMission`
///          for every `ChatBackendID`.
///      plus the trust and fan-out gates the GUI applied inline.
///   2. `BurnBarRemoteMissionAuthorizationPolicy.evaluate`, the daemon authority.
///
/// It asserts the same PERMISSIVENESS CLASS (allow / requires-approval / deny)
/// per row. Any residual divergence is an INTENTIONAL reconciliation, annotated
/// on the row and asserted explicitly. A green run here is the go/no-go for the
/// enforcement flip.
///
/// This lives in the daemon test target because that is the only place both the
/// shared `InsightMissionApprovalPolicy` (Core) and the daemon authority are
/// visible; the AgentLens target does not link the daemon module. The GUI's own
/// consent function is characterized separately by
/// AgentLensTests/`CLIAgentMissionRequestListenerMattersTests` and mirrored here
/// by the "non-hermes ⇒ consent" reconstruction.
final class MissionRemoteAuthorizationParityTests: XCTestCase {

    private enum Permissiveness: String, Equatable {
        case allow
        case requiresApproval
        case deny
    }

    private func daemonClass(
        _ response: BurnBarRemoteMissionAuthorizeResponse
    ) -> Permissiveness {
        switch response.verdict {
        case .authorized: return .allow
        case .requiresApproval: return .requiresApproval
        case .denied: return .deny
        }
    }

    private func requiresPreDispatchApproval(
        approvalMode: String?,
        commandsAllowed: Bool,
        fileEditsAllowed: Bool
    ) -> Bool {
        let normalizedMode = approvalMode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !(commandsAllowed || fileEditsAllowed) else { return true }
        switch normalizedMode {
        case "manual_all": return true
        case "risky_only", "existing_policy", "read_only", nil, "": return false
        default: return true
        }
    }

    /// The RESOLVED backend runtimes the GUI would forward. Every `ChatBackendID`
    /// rawValue plus the raw (non-enum) runtimes; only Hermes runs consent-free.
    private static let hermesRuntime = "hermes"
    private static let consentRuntimes = [
        "codex", "claude", "openclaw", "openclaude", "omp", "piAgent",
        "droid", "forge", "antigravity", "cursorAgent", "junie",
        "opencode", "ollama", "grok"
    ]

    /// The pre-M4 GUI decision, reconstructed purely (see class doc for the
    /// consent reconstruction). Mirrors the GUI's inline order:
    /// trust → fan-out → approval-rejected → approved → (shared policy OR consent).
    private func referenceGUIClass(
        trustState: String,
        approvalMode: String?,
        approvalStatus: String?,
        commandsAllowed: Bool,
        fileEditsAllowed: Bool,
        runtime: String,
        requestedFanOutCount: Int,
        trustedFanOutCap: Int
    ) -> Permissiveness {
        guard trustState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "trusted" else {
            return .deny
        }
        guard requestedFanOutCount >= 1, requestedFanOutCount <= trustedFanOutCap else {
            return .deny
        }
        let normalizedStatus = (approvalStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if ["rejected", "canceled", "cancelled"].contains(normalizedStatus) {
            return .deny
        }
        if normalizedStatus == "approved" {
            return .allow
        }
        let guiConsent = runtime
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() != Self.hermesRuntime
        let requiresApproval = requiresPreDispatchApproval(
            approvalMode: approvalMode,
            commandsAllowed: commandsAllowed,
            fileEditsAllowed: fileEditsAllowed
        ) || guiConsent
        return requiresApproval ? .requiresApproval : .allow
    }

    private struct Row {
        let name: String
        let trustState: String
        let approvalMode: String?
        let approvalStatus: String?
        let commands: Bool
        let fileEdits: Bool
        let runtime: String
        let fanOut: Int
        let cap: Int
        let intentionalDaemonClass: Permissiveness?
        let reconciliationNote: String?

        init(_ name: String, trust: String = "trusted", mode: String? = "existing_policy",
             status: String? = nil, commands: Bool = false, fileEdits: Bool = false,
             runtime: String = "hermes", fanOut: Int = 1, cap: Int = 1,
             intentional: Permissiveness? = nil, note: String? = nil) {
            self.name = name; self.trustState = trust; self.approvalMode = mode
            self.approvalStatus = status; self.commands = commands; self.fileEdits = fileEdits
            self.runtime = runtime; self.fanOut = fanOut; self.cap = cap
            self.intentionalDaemonClass = intentional; self.reconciliationNote = note
        }
    }

    private func rows() -> [Row] {
        [
            // Trust (a)
            Row("trusted hermes read-only runs"),
            Row("pending denies", trust: "pending", status: "approved"),
            Row("revoked denies", trust: "revoked"),
            Row("unknown trust denies", trust: "unknown_trust_state"),
            // Approval (b) — shared policy parity
            Row("hermes manual_all pauses", mode: "manual_all"),
            Row("hermes commands pause", commands: true),
            Row("hermes file edits pause", mode: nil, fileEdits: true),
            Row("hermes unknown mode fails closed", mode: "definitely_not_a_mode"),
            Row("approved runs even manual_all risky", mode: "manual_all", status: "approved", commands: true, fileEdits: true),
            Row("rejected denies", status: "rejected"),
            Row("cancelled denies", mode: "manual_all", status: "cancelled", commands: true),
            // Backend consent (b) — resolved-runtime parity
            Row("codex requires consent", runtime: "codex"),
            Row("claude requires consent", mode: nil, runtime: "claude"),
            Row("droid requires consent", runtime: "droid"),
            Row("junie requires consent", mode: nil, runtime: "junie"),
            Row("raw opencode requires consent", runtime: "opencode"),
            Row("raw ollama requires consent", runtime: "ollama"),
            // Fan-out (d) — daemon honors the GUI-resolved cap
            Row("free cap solo runs", status: "approved"),
            Row("free cap fan-out 2 denies", status: "approved", fanOut: 2, cap: 1),
            Row("cloud cap fan-out 3 runs", status: "approved", fanOut: 3, cap: 3),
            Row("pro cap fan-out 8 runs", status: "approved", fanOut: 8, cap: 8),
            Row("ultra cap fan-out 16 runs", status: "approved", fanOut: 16, cap: 16),
            Row("over-cap fan-out denies", status: "approved", fanOut: 9, cap: 8)
        ]
    }

    private func request(_ row: Row) -> BurnBarRemoteMissionAuthorizeRequest {
        BurnBarRemoteMissionAuthorizeRequest(
            missionID: "parity-\(row.name)",
            originDeviceID: "phone-1",
            originPlatform: "ios",
            executorTrustState: row.trustState,
            promptSummary: "parity row",
            promptSHA256: String(repeating: "ab", count: 32),
            requestedRuntime: row.runtime,
            requestedModelID: nil,
            requestedGrant: BurnBarRemoteMissionCapabilityGrantRequest(
                commandsAllowed: row.commands,
                fileEditsAllowed: row.fileEdits
            ),
            approvalMode: row.approvalMode,
            approvalStatus: row.approvalStatus,
            entitlementTier: "advisory-only",
            requestedFanOutCount: row.fanOut,
            trustedFanOutCap: row.cap
        )
    }

    func testGUIReducerAgreesWithDaemonAcrossTheTable() {
        for row in rows() {
            let guiClass = referenceGUIClass(
                trustState: row.trustState,
                approvalMode: row.approvalMode,
                approvalStatus: row.approvalStatus,
                commandsAllowed: row.commands,
                fileEditsAllowed: row.fileEdits,
                runtime: row.runtime,
                requestedFanOutCount: row.fanOut,
                trustedFanOutCap: row.cap
            )
            let observed = daemonClass(BurnBarRemoteMissionAuthorizationPolicy.evaluate(request(row)))

            if let intentional = row.intentionalDaemonClass {
                XCTAssertEqual(observed, intentional,
                    "INTENTIONAL divergence '\(row.name)': daemon must be \(intentional.rawValue). \(row.reconciliationNote ?? "")")
                XCTAssertNotEqual(observed, guiClass,
                    "'\(row.name)' marked intentional but the classes agree — remove the annotation")
            } else {
                XCTAssertEqual(observed, guiClass,
                    "PARITY BREAK '\(row.name)': GUI reference = \(guiClass.rawValue), daemon = \(observed.rawValue). "
                        + "If intentional, annotate the row; otherwise fix the daemon policy (the authority).")
            }
        }
    }

    /// Guards the load-bearing reconciliation: forwarding the RESOLVED backend
    /// runtime makes the daemon require approval for every non-Hermes backend
    /// and NOT for Hermes — exactly matching the GUI's per-backend consent.
    func testResolvedRuntimeConsentParity() {
        // Hermes: no consent → runs read-only.
        let hermes = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
            request(Row("hermes", runtime: Self.hermesRuntime))
        )
        XCTAssertEqual(hermes.verdict, .authorized, "hermes must run consent-free")
        // Every other resolved runtime: consent → requiresApproval on a read-only
        // mission (the consent branch, not the shared policy, is what pauses).
        for runtime in Self.consentRuntimes {
            let response = BurnBarRemoteMissionAuthorizationPolicy.evaluate(
                request(Row("consent-\(runtime)", runtime: runtime))
            )
            XCTAssertEqual(response.verdict, .requiresApproval,
                "resolved runtime '\(runtime)' must require consent-driven approval")
        }
    }
}
