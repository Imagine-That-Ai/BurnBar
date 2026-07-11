using System;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Switcher;

// PORTED (faithful, metadata-only) from AgentLens/Views/Settings/AccountSwitcher/
// AccountSwitcherProfileRowView.swift + the per-row flags computed in providerSection
// (AccountSwitcherSettingsView+Rendering.swift lines ~773-802).
//
// A row's display state (name, slot label, badges, the account-identity line) and its
// capability flags (move up/down, swap, make-primary, toggle-paused) are a pure function
// of the profile, its position in its group, and the active selection. This computes that
// exactly as the SwiftUI row does, minus the live CLI-auth-discovery fallback (platform
// I/O), which is a Windows dev-host integration. Unit-tested on macOS.

/// <summary>Computed row state for one profile inside a provider group.</summary>
public sealed class SwitcherProfileRowViewModel
{
    private SwitcherProfileRowViewModel(
        SwitcherProfileRecord profile,
        ProfileGroup group,
        int groupIndex,
        bool isActive,
        DateTimeOffset now)
    {
        Profile = profile;
        Group = group;
        BrandColorHex = group.BrandColorHex;

        int groupCount = group.Profiles.Count;

        // Swift: fallbackIndex = group.profiles.count > 1 ? groupIndex + 1 : nil
        SlotLabel = groupCount > 1 ? SwitcherProfileGrouping.SlotLabel(groupIndex + 1) : null;

        IsActive = isActive;
        IsDisabled = profile.IsDisabled;
        IsConnected = ComputeIsConnected(profile);
        AccountIdentityText = ComputeAccountIdentityText(profile, now);

        // Capability flags — Swift providerSection(_:) call site.
        CanMoveUp = groupIndex > 0;
        CanMoveDown = groupIndex < groupCount - 1;
        CanSwap = groupCount > 1;
        CanSetPrimary = groupCount > 1 && groupIndex > 0 && !profile.IsDisabled;
        CanToggleDisabled = group.EnabledCount > 1 || profile.IsDisabled;

        // Account-change is offered for browser profiles and Codex/Claude CLI profiles.
        CanChangeAccount = profile.TargetKind == SwitcherProfileTargetKind.Browser
            || profile.CliType is SwitcherCLIProfileType.Codex or SwitcherCLIProfileType.Claude;
    }

    public SwitcherProfileRecord Profile { get; }

    /// <summary>The owning provider group — carried for command routing from XAML rows.</summary>
    public ProfileGroup Group { get; }

    public string DisplayName => Profile.DisplayName;

    /// <summary>Provider brand color hex (RRGGBB) inherited from the group.</summary>
    public string BrandColorHex { get; }

    /// <summary>"primary" / "reserve N", or null when the group has a single profile.</summary>
    public string? SlotLabel { get; }

    /// <summary>Whether a slot badge should render (Swift shows it only when count > 1).</summary>
    public bool HasSlotLabel => SlotLabel is not null;

    /// <summary>Pause/resume action label. Swift: the paused-state toggle.</summary>
    public string PauseResumeLabel => IsDisabled ? "Resume" : "Pause";

    public bool IsActive { get; }

    public bool IsDisabled { get; }

    public bool IsConnected { get; }

    /// <summary>The account line under the name. Swift: <c>accountIdentityText</c> (metadata-only).</summary>
    public string AccountIdentityText { get; }

    public bool CanMoveUp { get; }

    public bool CanMoveDown { get; }

    public bool CanSwap { get; }

    public bool CanSetPrimary { get; }

    public bool CanToggleDisabled { get; }

    public bool CanChangeAccount { get; }

    /// <summary>Build every row for a group in order, with active + clock injected.</summary>
    public static System.Collections.Generic.IReadOnlyList<SwitcherProfileRowViewModel> ForGroup(
        ProfileGroup group,
        string? activeProfileId,
        DateTimeOffset now)
    {
        return group.Profiles
            .Select((item, index) => new SwitcherProfileRowViewModel(
                item.Profile, group, index, item.Profile.Id == activeProfileId, now))
            .ToList();
    }

    // Swift: AccountSwitcherProfileRowView.isConnected (metadata-only portion).
    private static bool ComputeIsConnected(SwitcherProfileRecord profile)
    {
        switch (profile.TargetKind)
        {
            case SwitcherProfileTargetKind.Cli:
                return !profile.IsDisabled
                    && !string.IsNullOrWhiteSpace(profile.CliMetadata?.AccountDescription);
            default:
                if (profile.IsDisabled)
                {
                    return false;
                }

                if (!string.IsNullOrEmpty(profile.BrowserMetadata?.AccountEmail))
                {
                    return true;
                }

                return (profile.BrowserMetadata?.ServiceIdentities.Count ?? 0) > 0;
        }
    }

    // Swift: AccountSwitcherProfileRowView.accountIdentityText (metadata-only portion).
    private static string ComputeAccountIdentityText(SwitcherProfileRecord profile, DateTimeOffset now)
    {
        if (profile.TargetKind == SwitcherProfileTargetKind.Cli)
        {
            if (profile.IsDisabled)
            {
                return "Paused — excluded from switching until re-enabled";
            }

            var account = profile.CliMetadata?.AccountDescription?.Trim();
            if (!string.IsNullOrEmpty(account))
            {
                return $"Connected: {account}";
            }

            if (profile.CliMetadata?.ExhaustedUntil is { } until && until > now)
            {
                return "Held in reserve until quota resets";
            }

            var label = profile.CliMetadata?.DisplayLabel;
            if (!string.IsNullOrEmpty(label))
            {
                return $"Not connected · {label}";
            }

            return "Not connected";
        }

        var meta = profile.BrowserMetadata;
        if (meta is null)
        {
            return profile.BrowserType?.DisplayName() ?? "Browser";
        }

        if (profile.IsDisabled)
        {
            return "Paused — excluded from browser switching until re-enabled";
        }

        string identityLabel = profile.BrowserType == SwitcherBrowserProfileType.Safari ? "Apple ID" : "Google";

        if (!string.IsNullOrEmpty(meta.AccountEmail))
        {
            return $"{identityLabel}: {meta.AccountEmail}";
        }

        if (!string.IsNullOrEmpty(meta.DisplayLabel))
        {
            return $"{identityLabel}: {meta.DisplayLabel}";
        }

        if (meta.ServiceIdentities.Count > 0)
        {
            return "Web sessions detected";
        }

        return "Not signed in";
    }
}
