using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Switcher;

// PORTED (faithful) from the grouping + summary passes in
// AgentLens/Views/Settings/AccountSwitcher/AccountSwitcherSettingsView+Rendering.swift:
//   • struct ProfileGroup
//   • var profileGroups  (canonical CLI order, then Chrome, then Safari)
//   • func providerSummary(for:)
//   • the primary/reserve slot label in AccountSwitcherProfileRowView.swift
//
// Pure list -> sections transform. The macOS view renders CLI groups first (Claude,
// Codex, OpenCode, Droid, Forge, Antigravity, Grok, Cursor Agent, Gemini, Kimi, Pi) then
// browser groups (Chrome, Safari); only providers with at least one profile appear. This
// is the same pass, unit-tested on macOS with no WinUI host.

/// <summary>A profile at its stable index in the flat list. Swift tuple: <c>(index, profile)</c>.</summary>
public sealed record IndexedProfile(int Index, SwitcherProfileRecord Profile);

/// <summary>One provider section. Swift: <c>AccountSwitcherSettingsView.ProfileGroup</c>.</summary>
public sealed class ProfileGroup
{
    public ProfileGroup(
        string key,
        string label,
        string glyph,
        string? bundledLogoName,
        string brandColorHex,
        IReadOnlyList<IndexedProfile> profiles,
        int connectedCount,
        int enabledCount,
        SwitcherCLIProfileType? cliType,
        SwitcherBrowserProfileType? browserType)
    {
        Key = key;
        Label = label;
        Glyph = glyph;
        BundledLogoName = bundledLogoName;
        BrandColorHex = brandColorHex;
        Profiles = profiles;
        ConnectedCount = connectedCount;
        EnabledCount = enabledCount;
        CliType = cliType;
        BrowserType = browserType;
    }

    /// <summary>Stable section key (Swift <c>cliType.rawValue</c> / "chrome" / "safari").</summary>
    public string Key { get; }

    public string Label { get; }

    /// <summary>Segoe MDL2 Assets glyph fallback when no bundled logo asset resolves.</summary>
    public string Glyph { get; }

    /// <summary>Bundled logo asset name, or null (Swift <c>bundledLogoName</c>).</summary>
    public string? BundledLogoName { get; }

    /// <summary>Provider brand color hex (RRGGBB, no '#'). Swift <c>ProfileGroup.color</c>.</summary>
    public string BrandColorHex { get; }

    public IReadOnlyList<IndexedProfile> Profiles { get; }

    /// <summary>Count of profiles with a confirmed session. Swift <c>connectedCount</c>.</summary>
    public int ConnectedCount { get; }

    /// <summary>Count of profiles not paused. Swift <c>enabledCount</c>.</summary>
    public int EnabledCount { get; }

    public SwitcherCLIProfileType? CliType { get; }

    public SwitcherBrowserProfileType? BrowserType { get; }

    public bool IsCli => CliType is not null;

    public bool IsBrowser => BrowserType is not null;

    /// <summary>
    /// Provider summary line. Swift: <c>providerSummary(for:)</c> — four branches keyed by
    /// connected/enabled counts and whether any profile is paused.
    /// </summary>
    public string Summary()
    {
        if (ConnectedCount == 0)
        {
            return BrowserType is null
                ? "No connected accounts yet. Add one to start rotating within this provider."
                : "No confirmed session detected yet. Connect one to launch with this provider.";
        }

        if (EnabledCount > 1)
        {
            return $"{EnabledCount} ready for same-provider handoff. Primary stays first and reserves wait behind it.";
        }

        if (Profiles.Any(p => p.Profile.IsDisabled))
        {
            return "Some accounts are paused. Re-enable them when you want them back in the rotation.";
        }

        return "One account is live. Add another to keep a reserve ready.";
    }
}

/// <summary>Grouping + labeling. Swift: <c>profileGroups</c> and the row slot label.</summary>
public static class SwitcherProfileGrouping
{
    // Swift `cliOrder` in AccountSwitcherSettingsView+Rendering.swift. Brand hex is copied
    // verbatim; OpenCode's adaptive `DesignSystem.Colors.whimsy` resolves to its DARK value
    // (8B7FE8) here because the Windows shell is dark-first (same rule ProviderBrand.cs uses).
    private static readonly (SwitcherCLIProfileType Type, string Label, string Glyph, string Hex, string? Logo)[] CliOrder =
    {
        (SwitcherCLIProfileType.Claude, "Claude Code", "", "CC785C", "ClaudeCodeLogo"),
        (SwitcherCLIProfileType.Codex, "Codex", "", "00A67E", "CodexLogo"),
        (SwitcherCLIProfileType.OpenCode, "OpenCode", "", "8B7FE8", null),
        (SwitcherCLIProfileType.Droid, "Droid", "", "8B5CF6", "FactoryLogo"),
        (SwitcherCLIProfileType.Forge, "Forge", "", "F97316", "ForgeLogo"),
        (SwitcherCLIProfileType.Antigravity, "Antigravity", "", "6C63FF", "AntigravityLogo"),
        (SwitcherCLIProfileType.Grok, "Grok Build", "", "111111", "GrokLogo"),
        (SwitcherCLIProfileType.CursorAgent, "Cursor Agent", "", "00E5FF", "CursorLogo"),
        (SwitcherCLIProfileType.Gemini, "Gemini CLI", "", "4285F4", "GeminiCLILogo"),
        (SwitcherCLIProfileType.Kimi, "Kimi", "", "6366F1", "KimiLogo"),
        (SwitcherCLIProfileType.Pi, "Pi", "", "7C3AED", "PiAgentLogo"),
    };

    /// <summary>
    /// Build the ordered provider sections. Swift: <c>profileGroups</c>. <paramref name="isConnected"/>
    /// classifies a profile as having a confirmed session; the default mirrors the pure,
    /// metadata-only portion of Swift <c>isConnectedProfile</c> (the live CLI-auth-discovery
    /// fallback is a Windows dev-host integration and is injected there).
    /// </summary>
    public static IReadOnlyList<ProfileGroup> ComputeGroups(
        IReadOnlyList<SwitcherProfileRecord> profiles,
        Func<SwitcherProfileRecord, bool>? isConnected = null)
    {
        var connected = isConnected ?? DefaultIsConnected;
        var indexed = (profiles ?? Array.Empty<SwitcherProfileRecord>())
            .Select((profile, index) => new IndexedProfile(index, profile))
            .ToList();

        var groups = new List<ProfileGroup>();

        foreach (var (type, label, glyph, hex, logo) in CliOrder)
        {
            var matching = indexed
                .Where(p => p.Profile.TargetKind == SwitcherProfileTargetKind.Cli && p.Profile.CliType == type)
                .ToList();
            if (matching.Count == 0)
            {
                continue;
            }

            groups.Add(new ProfileGroup(
                key: type.RawValue(),
                label: label,
                glyph: glyph,
                bundledLogoName: logo,
                brandColorHex: hex,
                profiles: matching,
                connectedCount: matching.Count(p => connected(p.Profile)),
                enabledCount: matching.Count(p => !p.Profile.IsDisabled),
                cliType: type,
                browserType: null));
        }

        AppendBrowserGroup(
            groups, indexed, connected,
            SwitcherBrowserProfileType.Chrome, "chrome", "Google Chrome", "", "ChromeLogo", "4285F4");
        AppendBrowserGroup(
            groups, indexed, connected,
            SwitcherBrowserProfileType.Safari, "safari", "Safari", "", "SafariLogo", "0071E3");

        return groups;
    }

    /// <summary>CLI-only sections. Swift: <c>cliProfileGroups</c>.</summary>
    public static IReadOnlyList<ProfileGroup> CliGroups(IReadOnlyList<ProfileGroup> groups) =>
        groups.Where(g => g.IsCli).ToList();

    /// <summary>Browser-only sections. Swift: <c>browserProfileGroups</c>.</summary>
    public static IReadOnlyList<ProfileGroup> BrowserGroups(IReadOnlyList<ProfileGroup> groups) =>
        groups.Where(g => g.IsBrowser).ToList();

    /// <summary>
    /// Primary/reserve slot label for a 1-based position in its group. Swift:
    /// <c>idx == 1 ? "primary" : "reserve \(idx - 1)"</c>.
    /// </summary>
    public static string SlotLabel(int oneBasedIndex) =>
        oneBasedIndex == 1 ? "primary" : $"reserve {oneBasedIndex - 1}";

    /// <summary>
    /// Metadata-only connection heuristic. Swift <c>isConnectedProfile</c> minus the live
    /// CLI-auth-discovery fallback (which is platform I/O supplied by the host).
    /// </summary>
    public static bool DefaultIsConnected(SwitcherProfileRecord profile)
    {
        switch (profile.TargetKind)
        {
            case SwitcherProfileTargetKind.Cli:
                if (profile.IsDisabled)
                {
                    return false;
                }

                return !string.IsNullOrWhiteSpace(profile.CliMetadata?.AccountDescription);
            default:
                if (!string.IsNullOrEmpty(profile.BrowserMetadata?.AccountEmail))
                {
                    return true;
                }

                return (profile.BrowserMetadata?.ServiceIdentities.Count ?? 0) > 0;
        }
    }

    private static void AppendBrowserGroup(
        List<ProfileGroup> groups,
        List<IndexedProfile> indexed,
        Func<SwitcherProfileRecord, bool> connected,
        SwitcherBrowserProfileType type,
        string key,
        string label,
        string glyph,
        string logo,
        string hex)
    {
        var matching = indexed
            .Where(p => p.Profile.TargetKind == SwitcherProfileTargetKind.Browser && p.Profile.BrowserType == type)
            .ToList();
        if (matching.Count == 0)
        {
            return;
        }

        groups.Add(new ProfileGroup(
            key: key,
            label: label,
            glyph: glyph,
            bundledLogoName: logo,
            brandColorHex: hex,
            profiles: matching,
            connectedCount: matching.Count(p => connected(p.Profile)),
            enabledCount: matching.Count(p => !p.Profile.IsDisabled),
            cliType: null,
            browserType: type));
    }
}
