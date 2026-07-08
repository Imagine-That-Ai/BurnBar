using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Switcher;

/// <summary>
/// Dev-host seed for the Windows account-switcher surface. The Windows analog of the SessionLogs
/// live-stream stub / the Budget <c>SeedRules()</c> fixture: an <see cref="InMemorySwitcherProfileStore"/>
/// pre-populated with a couple of CLI + browser profiles so the hosted <c>SwitcherSettingsView</c>
/// renders real grouped sections before the encrypted Windows profile store lands (storage seam).
///
/// This carries ONLY non-sensitive launch metadata (labels + account descriptions) — no OAuth
/// tokens, cookies, or API keys — matching the <see cref="SwitcherProfileRecord"/> security contract.
/// Kept in the portable (net8.0, no-WinUI) layer so it is exercised by <c>dotnet test</c> on macOS.
/// </summary>
public static class SwitcherSampleData
{
    /// <summary>A fixed clock so the seeded records are deterministic under test.</summary>
    public static readonly DateTimeOffset SeedNow = new(2026, 7, 4, 12, 0, 0, TimeSpan.Zero);

    /// <summary>
    /// A store seeded with <see cref="DevHostProfiles"/>, its first CLI profile marked active.
    /// The host page injects this into a <see cref="SwitcherSettingsViewModel"/> and calls
    /// <c>Load()</c>.
    /// </summary>
    public static InMemorySwitcherProfileStore CreateDevHostStore(Func<DateTimeOffset>? now = null)
    {
        var profiles = DevHostProfiles();
        return new InMemorySwitcherProfileStore(profiles, activeProfileId: profiles[0].Id, now ?? (() => SeedNow));
    }

    /// <summary>The seeded CLI + browser profiles, in sidebar (sort) order.</summary>
    public static IReadOnlyList<SwitcherProfileRecord> DevHostProfiles() => new List<SwitcherProfileRecord>
    {
        Cli("dev-codex-work", SwitcherCLIProfileType.Codex, account: "work@imagine-that.ai", label: "Codex · work"),
        Cli("dev-claude-personal", SwitcherCLIProfileType.Claude, account: "alberto@imagine-that.ai", label: "Claude Code · personal"),
        Cli("dev-droid-ci", SwitcherCLIProfileType.Droid, account: "ci@imagine-that.ai", label: "Droid · CI", disabled: true),
        Browser("dev-chrome-openai", SwitcherBrowserProfileType.Chrome, profileIdentifier: "Default", label: "Chrome · ChatGPT", email: "alberto@imagine-that.ai", providerIdentifier: "openai"),
        Browser("dev-chrome-claude", SwitcherBrowserProfileType.Chrome, profileIdentifier: "Profile 1", label: "Chrome · Claude", email: "alberto@imagine-that.ai", providerIdentifier: "claude"),
    };

    private static SwitcherProfileRecord Cli(
        string id,
        SwitcherCLIProfileType type,
        string? account = null,
        string? label = null,
        bool disabled = false) =>
        new(
            Id: id,
            TargetKind: SwitcherProfileTargetKind.Cli,
            SortKey: 0,
            CliType: type,
            CliMetadata: new SwitcherCLIProfileMetadata(
                DisplayLabel: label,
                AccountDescription: account,
                IsDisabled: disabled),
            CreatedAt: SeedNow,
            UpdatedAt: SeedNow);

    private static SwitcherProfileRecord Browser(
        string id,
        SwitcherBrowserProfileType type,
        string profileIdentifier,
        string? label = null,
        string? email = null,
        string? providerIdentifier = null) =>
        new(
            Id: id,
            TargetKind: SwitcherProfileTargetKind.Browser,
            SortKey: 0,
            BrowserType: type,
            BrowserMetadata: new SwitcherBrowserProfileMetadata(
                ProfileIdentifier: profileIdentifier,
                DisplayLabel: label,
                AccountEmail: email,
                ProviderIdentifier: providerIdentifier),
            CreatedAt: SeedNow,
            UpdatedAt: SeedNow);
}
