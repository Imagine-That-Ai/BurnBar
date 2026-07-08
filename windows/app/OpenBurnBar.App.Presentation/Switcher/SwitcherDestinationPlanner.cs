using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Switcher;

// PORTED (faithful) from:
//   AgentLens/Views/Settings/AccountSwitcher/AccountSwitcherSupport.swift
//     — AccountChangeDestination + BrowserAccountChangePlanner
//   AgentLens/Views/Settings/AccountSwitcher/AccountSwitcherSettingsView+DataOperations.swift
//     — serviceDestinations / preferredAccountChangeDestination /
//       defaultAccountChangeDestination / availableAccountChangeDestinations /
//       browserProviderIdentifier
//
// This is the PURE account-change routing core: given a profile's provider identifier
// and detected service identities, decide which sign-in destinations to offer and which
// one to pre-select. The macOS view calls exactly this to build the destination-picker
// sheet; the Windows view calls it to build the destination-picker ContentDialog. No UI,
// no I/O — unit-tested on macOS.

/// <summary>Where a "switch account" flow can send the user. Swift: <c>AccountChangeDestination</c>.</summary>
public enum AccountChangeDestination
{
    OpenAI,
    Claude,
    GoogleAccount,
    AppleID,
}

/// <summary>Display + routing metadata for <see cref="AccountChangeDestination"/>.</summary>
public static class AccountChangeDestinationMetadata
{
    public static string Label(this AccountChangeDestination d) => d switch
    {
        AccountChangeDestination.OpenAI => "OpenAI / Codex",
        AccountChangeDestination.Claude => "Claude",
        AccountChangeDestination.GoogleAccount => "Google Account",
        _ => "Apple ID",
    };

    public static string Subtitle(this AccountChangeDestination d) => d switch
    {
        AccountChangeDestination.OpenAI => "chatgpt.com",
        AccountChangeDestination.Claude => "claude.ai",
        AccountChangeDestination.GoogleAccount => "myaccount.google.com",
        _ => "appleid.apple.com",
    };

    /// <summary>Segoe MDL2 Assets glyph analog of the Swift SF Symbol (best-effort parity).</summary>
    public static string Glyph(this AccountChangeDestination d) => d switch
    {
        AccountChangeDestination.OpenAI => "\uE8BD",        // Message
        AccountChangeDestination.Claude => "\uE8F2",        // ChatBubbles
        AccountChangeDestination.GoogleAccount => "\uE8D7", // Permissions / badge.key
        _ => "\uE77B",                                      // Contact (apple.logo has no MDL2 glyph)
    };

    /// <summary>Accent color hex. Swift: <c>accentColor</c> (Color(hex:)).</summary>
    public static string AccentColorHex(this AccountChangeDestination d) => d switch
    {
        AccountChangeDestination.OpenAI => "00A67E",
        AccountChangeDestination.Claude => "CC785C",
        AccountChangeDestination.GoogleAccount => "4285F4",
        _ => "0071E3",
    };

    /// <summary>Swift: <c>requiresInteractiveAuth</c> (Google/Apple trigger real OAuth).</summary>
    public static bool RequiresInteractiveAuth(this AccountChangeDestination d) => d switch
    {
        AccountChangeDestination.GoogleAccount or AccountChangeDestination.AppleID => true,
        _ => false,
    };

    /// <summary>Sign-in URL. Swift: <c>url</c>.</summary>
    public static string Url(this AccountChangeDestination d) => d switch
    {
        AccountChangeDestination.OpenAI => "https://chatgpt.com/",
        AccountChangeDestination.Claude => "https://claude.ai/",
        AccountChangeDestination.GoogleAccount =>
            "https://accounts.google.com/AccountChooser?continue=https://myaccount.google.com/",
        _ => "https://appleid.apple.com/sign-in",
    };

    /// <summary>Swift: <c>AccountChangeDestination.browserServiceProvider</c>.</summary>
    public static BrowserServiceProvider? BrowserServiceProvider(this AccountChangeDestination d) => d switch
    {
        AccountChangeDestination.OpenAI => Switcher.BrowserServiceProvider.OpenAI,
        AccountChangeDestination.Claude => Switcher.BrowserServiceProvider.Claude,
        _ => null,
    };
}

/// <summary>
/// Pure destination routing. Swift: <c>BrowserAccountChangePlanner</c> +
/// the destination helpers on <c>AccountSwitcherSettingsView</c>.
/// </summary>
public static class SwitcherDestinationPlanner
{
    /// <summary>
    /// Ordered, deduped destinations for a browser profile. Swift:
    /// <c>BrowserAccountChangePlanner.destinations</c> — provider first (apple/google),
    /// then one per detected service, then OpenAI + Claude as universal fallbacks.
    /// </summary>
    public static IReadOnlyList<AccountChangeDestination> BrowserDestinations(
        string? providerIdentifier,
        IReadOnlyList<BrowserServiceIdentity> serviceIdentities)
    {
        var ordered = new List<AccountChangeDestination>();

        void Append(AccountChangeDestination destination)
        {
            if (!ordered.Contains(destination))
            {
                ordered.Add(destination);
            }
        }

        switch (providerIdentifier?.Trim().ToLowerInvariant())
        {
            case "apple":
                Append(AccountChangeDestination.AppleID);
                break;
            case "google":
                Append(AccountChangeDestination.GoogleAccount);
                break;
        }

        foreach (var identity in serviceIdentities ?? Array.Empty<BrowserServiceIdentity>())
        {
            switch (identity.Provider)
            {
                case Switcher.BrowserServiceProvider.OpenAI:
                    Append(AccountChangeDestination.OpenAI);
                    break;
                case Switcher.BrowserServiceProvider.Claude:
                    Append(AccountChangeDestination.Claude);
                    break;
            }
        }

        Append(AccountChangeDestination.OpenAI);
        Append(AccountChangeDestination.Claude);

        return ordered;
    }

    /// <summary>
    /// Destinations backed by the profile's detected services (deduped, order preserved).
    /// Swift: <c>serviceDestinations(for:)</c>.
    /// </summary>
    public static IReadOnlyList<AccountChangeDestination> ServiceDestinations(SwitcherProfileRecord profile)
    {
        var identities = profile.BrowserMetadata?.ServiceIdentities ?? Array.Empty<BrowserServiceIdentity>();
        var result = new List<AccountChangeDestination>();
        foreach (var identity in identities)
        {
            var destination = identity.Provider == Switcher.BrowserServiceProvider.OpenAI
                ? AccountChangeDestination.OpenAI
                : AccountChangeDestination.Claude;
            if (!result.Contains(destination))
            {
                result.Add(destination);
            }
        }

        return result;
    }

    /// <summary>
    /// The single destination to auto-open when exactly one service is detected, else null.
    /// Swift: <c>preferredAccountChangeDestination(for:)</c>.
    /// </summary>
    public static AccountChangeDestination? PreferredAccountChangeDestination(SwitcherProfileRecord profile)
    {
        var services = ServiceDestinations(profile);
        return services.Count == 1 ? services[0] : null;
    }

    /// <summary>Default reconnect destination for a CLI profile. Swift: <c>defaultAccountChangeDestination(for:)</c>.</summary>
    public static AccountChangeDestination? DefaultAccountChangeDestination(SwitcherProfileRecord profile) => profile.CliType switch
    {
        SwitcherCLIProfileType.Codex => AccountChangeDestination.OpenAI,
        SwitcherCLIProfileType.Claude => AccountChangeDestination.Claude,
        _ => null,
    };

    /// <summary>
    /// The full destination list a profile offers. Swift: <c>availableAccountChangeDestinations(for:)</c>
    /// — browser profiles use <see cref="BrowserDestinations"/>; others fall back to their
    /// service destinations.
    /// </summary>
    public static IReadOnlyList<AccountChangeDestination> AvailableAccountChangeDestinations(SwitcherProfileRecord profile)
    {
        if (profile.TargetKind != SwitcherProfileTargetKind.Browser)
        {
            return ServiceDestinations(profile);
        }

        return BrowserDestinations(
            BrowserProviderIdentifier(profile),
            profile.BrowserMetadata?.ServiceIdentities ?? Array.Empty<BrowserServiceIdentity>());
    }

    /// <summary>Effective provider identifier for a browser profile. Swift: <c>browserProviderIdentifier(for:)</c>.</summary>
    public static string BrowserProviderIdentifier(SwitcherProfileRecord profile)
    {
        var provider = profile.BrowserMetadata?.ProviderIdentifier?.Trim();
        if (!string.IsNullOrEmpty(provider))
        {
            return provider!.ToLowerInvariant();
        }

        return profile.BrowserType switch
        {
            SwitcherBrowserProfileType.Safari => "apple",
            _ => "google",
        };
    }
}
