using System.Collections.Generic;

namespace OpenBurnBar.App.Settings.ViewModels.Daemon;

/// <summary>
/// One row of the F1 Ship Peer vs F2 True 1:1 scope table shown in Engine Room
/// (and mirrored in the certification bundle). Source: master plan §1 / strategy V2.
/// </summary>
public sealed record WindowsFinishLineScopeRow(
    string Area,
    string F1ShipPeer,
    string F2TrueOneToOne);

/// <summary>
/// Static F1/F2 finish-line vocabulary for the Engine Room settings surface.
/// Product default is F1; F2 is an explicit post-F1 program unless product overrides.
/// </summary>
public static class WindowsFinishLineScope
{
    public const string DefaultLabel = "F1 — Ship Peer (default launch target)";

    public const string Explainer =
        "Do not claim \"100% parity\" without naming F1 or F2. Rows below are Ship Peer / True 1:1 " +
        "exit criteria — not current-build capability claims (see ledger for status). F1 is the " +
        "default launch target under accepted WPDs; F2 adds deferred daemon/gateway depth " +
        "(WPD-0006 / WPD-0003). WinUI Daemon tab binding is H6 residual.";

    public static IReadOnlyList<WindowsFinishLineScopeRow> Rows { get; } = new List<WindowsFinishLineScopeRow>
    {
        new(
            "Local peer desktop",
            "Log ingest, quota, budget, storage, session logs, dashboard, insights, memory, DCC, onboarding, switcher, tray, settings",
            "F1 plus deeper Mac-only product completeness"),
        new(
            "Chat",
            "Production IChatStreamDriver for configured CLI backends (stream-json → ChatStreamEvent)",
            "Hermes/Pi gateway-backed chat + multi-client gateway"),
        new(
            "Cloud / auth",
            "Desktop OAuth, Firestore, App Check, CloudVault live, trusted-device graph",
            "Same plane with any F2-only connectors"),
        new(
            "Computer Use",
            "Windows desktop loop (SendInput/UIA/WGC) + audit + kill switch",
            "Plus browser/Playwright Computer Use path"),
        new(
            "Mission Control",
            "Firestore dispatch console (client)",
            "Local DAG execution, planner, policy engine, headless runs"),
        new(
            "Daemon / Model Proxy",
            "WPD-0006 matrix + deferred disclosure (no live local HTTP gateway required)",
            "Live local HTTP gateway, model proxy, provider router, metrics"),
        new(
            "Projects depth",
            "IA route + list-level peer; lexical-only disclosure where needed",
            "Full project-code static parser (WPD-0003 revive)"),
        new(
            "Distribution",
            "Signed MSIX, update proof, winget/Store-ready metadata, evidence bundle",
            "Same distribution bar after F2 product work"),
    };
}
