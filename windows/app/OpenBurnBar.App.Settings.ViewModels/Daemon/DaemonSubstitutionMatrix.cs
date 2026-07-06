// The 34-row WPD-0006 capability matrix, transcribed 1:1 from
// docs/windows-port/decisions/0006-windows-daemon-strategy.md ("The capability matrix").
//
// Row order, capability names, dispositions, qualifiers, and the SUB-DONE/SUB-BUILD
// hybrids (rows 24, 27) match the doc exactly. The disposition-summary constants match
// the doc's "Disposition summary" table (9 SUB-DONE, 3 SUB-BUILD, 18 DEFER, 4 N/A).
// A test cross-checks both against those figures so the tab can never drift from the
// accepted decision without a red build.

using System.Collections.Generic;
using System.Linq;
using D = OpenBurnBar.App.Settings.ViewModels.Daemon.DaemonSubstitutionDisposition;

namespace OpenBurnBar.App.Settings.ViewModels.Daemon;

/// <summary>The WPD-0006 per-capability substitution matrix (source of truth for the Engine Room tab).</summary>
public static class DaemonSubstitutionMatrix
{
    /// <summary>Stable WPD-0006 identifier surfaced in the tab header.</summary>
    public const string DecisionId = "WPD-0006";

    /// <summary>The decision doc path, for the "read the decision" affordance.</summary>
    public const string DecisionDocPath = "docs/windows-port/decisions/0006-windows-daemon-strategy.md";

    // ── The 34 capability rows in exact WPD-0006 order ────────────────────────
    private static readonly DaemonSubstitutionRow[] MatrixRows =
    {
        new(1, "HTTP gateway server (routing pipeline, endpoints, transport, connection mgmt)",
            D.Deferred,
            "No Windows v1 surface consumes the local proxy; excluded even from the daemon's Linux build. Revive trigger 3.",
            "WPD-0006 deferral ledger; bundle drift D14"),
        new(2, "Gateway model catalog + model health",
            D.Deferred, "Rides the gateway (row 1).", "With row 1"),
        new(3, "Cross-vendor degrade policy",
            D.Deferred, "Rides the gateway (row 1).", "With row 1"),
        new(4, "Gateway metrics / route logging / streaming usage accumulation",
            D.Deferred, "Rides the gateway (row 1).", "With row 1"),
        new(5, "Usage recording (durable token-usage rows in the shared DB)",
            D.SubstitutedAlready,
            "TokenUsageWriteSeam + TokenUsageReadSeam write/read the same byte-compat DB (WPD-0004).",
            "Landed (#1251/#1267)"),
        new(6, "Provider router (+ quota-drain ranking/metadata)",
            D.Deferred,
            "Serves gateway + headless runs, neither in v1. Compiles off-macOS today — revives via the Linux boundary build.",
            "Revisit triggers 1/3", Qualifier: "SWIFT-REUSE on revive"),
        new(7, "Provider executors (Anthropic, Codex, FactoryDroid, Ollama-native, OpenAI-compatible bridges)",
            D.Deferred,
            "Windows v1 chat executes agent CLIs directly (row 9), not via daemon API executors.",
            "Revisit triggers 1/3", Qualifier: "SWIFT-REUSE on revive"),
        new(8, "Headless run service: run/resume/recovery/journal, agent loop, tool dispatch",
            D.Deferred,
            "Headless runs that outlive the app are exactly revisit trigger 1. In-app interactive sessions are covered (row 9).",
            "Revisit trigger 1", Qualifier: "SWIFT-REUSE on revive"),
        new(9, "Interactive CLI/PTY session execution",
            D.SubstitutedAlready,
            "ConPtyCliStream over ConPtySession (B1); live-host proof rides the WS-D pass.",
            "Landed (#1267); live proof Wave 4"),
        new(10, "RPC server (Unix-socket JSON-RPC, 13 capability extensions)",
            D.NotApplicable,
            "Single-process architecture (WPD-0007): the app calls engine/storage in-process; there is no second process to serve RPC to in v1.",
            "Revives with any trigger"),
        new(11, "Peer-auth transport (codesign peer gate, token file, local auth proof)",
            D.SubstitutedAlready,
            "NamedPipePeerAuthListener/Connector implement the hardened equivalent (R16).",
            "Landed; consumed at WS-D", Qualifier: "transport primitive"),
        new(12, "Daemon self code-signature verifier",
            D.SubstitutedAlready,
            "dist hardening (WinVerifyTrust + DLL-load hardening, R19/D10). G5 proves it on a signed build.",
            "Wave 5 (G5 evidence)", Qualifier: "posture"),
        new(13, "Mission dispatch client (write mission requests, status polling)",
            D.SubstitutedAlready,
            "FirestoreMissionDispatchHost writes the same cli_agent_mission_requests envelope; hardened status polling per #1272. Execution stays on the Mac host.",
            "Landed (#1267 + #1272); surface → Real in Wave 3"),
        new(14, "Mission Control execution: DAG scheduler, journal repository, projection reducer, state merger, store",
            D.Deferred,
            "Windows v1 is a dispatch + console client; local mission execution is a headless-daemon duty (revisit trigger 1). Whole module compiles off-macOS.",
            "Revisit trigger 1", Qualifier: "SWIFT-REUSE on revive"),
        new(15, "Notification bridge: local notifications",
            D.SubstitutedAlready,
            "BudgetToastNotifier is the landed WinRT AppNotification seam; mission notifications ride it if/when local execution revives.",
            "Landed; live toast proof Wave 4/5 pass", Qualifier: "seam"),
        new(16, "Notification bridge: Telegram",
            D.Deferred,
            "Pure-HTTP portable code, but only fires from local mission execution (row 14). Deferred with it.",
            "With row 14"),
        new(17, "Notification bridge: EventKit (calendar/reminders)",
            D.NotApplicable,
            "EventKit is Apple-only; no Windows analog in scope (a Graph-calendar substitute would be a new feature, not parity).",
            "Bundle drift D14"),
        new(18, "Pensieve knowledge watcher",
            D.Deferred,
            "Excluded even from the daemon's Linux build; the Windows memory surface already reads/writes memory_facts via CloudSyncMemoryStore (B4). Local knowledge watching is a v1.1 capability.",
            "Bundle drift D14"),
        new(19, "Project-code memory store + embeddings",
            D.Deferred,
            "Already governed by WPD-0003 (static parser deferred; lexical fallback = bundle drift D13). Store follows the parser.",
            "WPD-0003; D13"),
        new(20, "Planner service",
            D.Deferred,
            "Serves mission planning for daemon-executed runs (rows 8/14). The Mac-side listener keeps owning planning for dispatched missions.",
            "With rows 8/14"),
        new(21, "Policy engine (run/tool approval)",
            D.Deferred,
            "Gates daemon-executed runs (row 8). The computer-use policy core is separately substituted (row 24).",
            "With row 8"),
        new(22, "Rate limiter",
            D.Deferred, "Gateway-scoped (row 1).", "With row 1"),
        new(23, "Config store / daemon configuration",
            D.SubstitutedAlready,
            "AppConfiguration owns Windows app/runtime config; daemon-endpoint config has no consumer without a daemon.",
            "Landed; gateway config revives with row 1", Qualifier: "app-scoped"),
        new(24, "Computer-use policy/capability/audit core + service coordination",
            D.SubstitutedAlready,
            "Core substituted: OpenBurnBar.ComputerUse.Core (Capability/Gate/Scope/Audit, ~100 tests) + Windows adapters. Full loop on real hardware = Wave 4 item 1 (G4).",
            "Wave 4 item 1", RemainderDisposition: D.SubstituteToBuild, Qualifier: "core"),
        new(25, "Browser tool service (Playwright driver/lifecycle, browser target policy)",
            D.Deferred,
            "Browser-driven computer-use is not in the Wave 4 G4 scope (SendInput/UIA/WGC/ViGEm loop is). Named v1.1 deferral.",
            "Bundle drift D14"),
        new(26, "Privileged input execution + virtual HID bridge",
            D.SubstituteToBuild,
            "Windows path = ViGEm + the watchdog process, Wave 4 item 1 (R17/D11). Secure-desktop/lock-screen injection stays the §15.1 v1.1 non-goal (signed driver).",
            "Wave 4 item 1; §15.1"),
        new(27, "Kill-switch watchdog",
            D.SubstitutedAlready,
            "Protocol/core landed (KillSwitch.cs, WatchdogProtocol.cs); the independent watchdog process + signed local kill channel is Wave 4 item 1 (R17).",
            "Wave 4 item 1", RemainderDisposition: D.SubstituteToBuild, Qualifier: "protocol"),
        new(28, "Remote access agent (+Core) and privileged-socket red-team probe",
            D.NotApplicable,
            "Their duties (input/screen/attestation plumbing) are absorbed by the in-process computer-use adapters; a separate agent process only returns if WS-D demands isolation (trigger 2).",
            "Revisit trigger 2", Qualifier: "as separate v1 processes"),
        new(29, "Companion CLI (OpenBurnBarCLI)",
            D.Deferred,
            "The CLI is a daemon-socket client; with no daemon there is nothing to drive. Revives with trigger 1 (headless).",
            "Revisit trigger 1"),
        new(30, "Switcher shell (account-switched shells/profiles)",
            D.SubstituteToBuild,
            "Profile persistence seam already landed (SwitcherProfileWriteSeam); the switcher surface converts sample → Real in Wave 3 item 1, spawn path via CreateProcess/ConPTY.",
            "Wave 3 item 1"),
        new(31, "Indexed search service",
            D.SubstituteToBuild,
            "Windows search is app-side: SettingsSearchEngine (landed) + the command-palette stub search called out in Wave 3 item 1; session-log search rides the storage read seam.",
            "Wave 3 item 1"),
        new(32, "Elder Wand orchestration (fusion orchestrator, tool loop, web tools)",
            D.Deferred,
            "Orchestrated multi-model fusion is gateway/run-service-coupled. The Windows Elder Wand surface + preset persistence convert in Wave 3 item 1 (bundle D8 covers reachability drift).",
            "Wave 3 (surface); orchestration with rows 1/8"),
        new(33, "Connector plane + connector secret store; tooling proxy; workspace bridge broker; context selector",
            D.Deferred,
            "Adjuncts of the headless run/gateway plane (rows 1/8); no v1 consumer.",
            "With rows 1/8"),
        new(34, "Daemon lifecycle glue: heartbeat, client registry, logger, DB cipher bootstrap, Keychain interaction gate, phone-key pin store",
            D.NotApplicable,
            "Process-lifecycle plumbing for a process that doesn't exist on Windows v1. DB cipher duty is already served by the WPD-0004 seam; secrets follow R15 (TPM/CNG, Wave 2), not Keychain semantics.",
            "Revives with any trigger"),
    };

    /// <summary>The 34 capability rows in WPD-0006 order.</summary>
    public static IReadOnlyList<DaemonSubstitutionRow> Rows => MatrixRows;

    // ── WPD-0006 "Disposition summary" figures (the doc's own totals) ─────────

    /// <summary>SUB-DONE count from the doc's summary (rows 5, 9, 11, 12, 13, 15, 23, 24, 27).</summary>
    public const int SubstitutedAlreadyCount = 9;

    /// <summary>SUB-BUILD count from the doc's summary (rows 26, 30, 31).</summary>
    public const int SubstituteToBuildCount = 3;

    /// <summary>DEFER count from the doc's summary (18 rows).</summary>
    public const int DeferredCount = 18;

    /// <summary>N/A count from the doc's summary (rows 10, 17, 28, 34).</summary>
    public const int NotApplicableCount = 4;

    /// <summary>Total capability rows (must equal the four summary counts).</summary>
    public const int TotalCount = 34;

    /// <summary>
    /// Count of rows whose PRIMARY disposition is <paramref name="disposition"/>. Rows 24
    /// and 27 count as SUB-DONE (their SUB-BUILD remainder is tracked separately), matching
    /// the doc's "counting each row by its primary v1 disposition".
    /// </summary>
    public static int CountByPrimaryDisposition(DaemonSubstitutionDisposition disposition) =>
        MatrixRows.Count(r => r.Disposition == disposition);

    /// <summary>Rows whose primary disposition matches <paramref name="disposition"/>, in matrix order.</summary>
    public static IReadOnlyList<DaemonSubstitutionRow> RowsWith(DaemonSubstitutionDisposition disposition) =>
        MatrixRows.Where(r => r.Disposition == disposition).ToArray();
}
