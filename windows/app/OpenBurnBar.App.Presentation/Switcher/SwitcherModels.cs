using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Switcher;

// PORTED (faithful) from OpenBurnBarCore/Sources/OpenBurnBarCore/SwitcherProfile.swift.
//
// This is the DEPENDENCY-FREE record + enum layer behind the Windows account-switcher
// surface (AgentLens/Views/Settings/AccountSwitcher/*). The SAME managed assembly is
// x:Bound by the WinUI views under windows/app/OpenBurnBar.App/Switcher/ AND unit-tested
// on the macOS authoring host via `dotnet test` (windows/tests/presentation), matching
// the SessionLogs/Memory pattern already landed in this lib.
//
// SECURITY (VAL-SETTINGS-008, mirrored from the Swift doc-comments): these records carry
// ONLY non-sensitive launch metadata — no OAuth tokens, passwords, cookies, API keys, or
// session credentials. Launch adapters resolve those at runtime from the OS credential
// store; nothing secret is persisted here.

/// <summary>The class of target a switcher profile controls. Swift: <c>SwitcherProfileTargetKind</c>.</summary>
public enum SwitcherProfileTargetKind
{
    Browser,
    Cli,
}

/// <summary>Supported browser targets. Swift: <c>SwitcherBrowserProfileType</c>.</summary>
public enum SwitcherBrowserProfileType
{
    Chrome,
    Safari,
}

/// <summary>Supported CLI targets. Swift: <c>SwitcherCLIProfileType</c> (declaration order preserved).</summary>
public enum SwitcherCLIProfileType
{
    Codex,
    Claude,
    OpenCode,
    Droid,
    Forge,
    Antigravity,
    Grok,
    CursorAgent,
    Omp,
    Gemini,
    Kimi,
    Pi,
}

/// <summary>Detected web-service provider inside a browser profile. Swift: <c>BrowserServiceProvider</c>.</summary>
public enum BrowserServiceProvider
{
    OpenAI,
    Claude,
}

/// <summary>
/// Raw-value + display-string parity helpers for the switcher enums. Mirrors the Swift
/// <c>rawValue</c>/<c>displayName</c>/<c>executableName</c> members and the
/// <c>canonicalAgentProvider.providerID.rawValue</c> bridge used for drain-target keys.
/// </summary>
public static class SwitcherEnumMetadata
{
    public static string RawValue(this SwitcherProfileTargetKind kind) => kind switch
    {
        SwitcherProfileTargetKind.Browser => "browser",
        _ => "cli",
    };

    public static string RawValue(this SwitcherBrowserProfileType type) => type switch
    {
        SwitcherBrowserProfileType.Chrome => "chrome",
        _ => "safari",
    };

    public static string DisplayName(this SwitcherBrowserProfileType type) => type switch
    {
        SwitcherBrowserProfileType.Chrome => "Google Chrome",
        _ => "Safari",
    };

    public static string RawValue(this BrowserServiceProvider provider) => provider switch
    {
        BrowserServiceProvider.OpenAI => "openai",
        _ => "claude",
    };

    public static string DisplayName(this BrowserServiceProvider provider) => provider switch
    {
        BrowserServiceProvider.OpenAI => "OpenAI",
        _ => "Claude",
    };

    /// <summary>Swift <c>rawValue</c> (note <c>cursorAgent == "cursoragent"</c>).</summary>
    public static string RawValue(this SwitcherCLIProfileType type) => type switch
    {
        SwitcherCLIProfileType.Codex => "codex",
        SwitcherCLIProfileType.Claude => "claude",
        SwitcherCLIProfileType.OpenCode => "opencode",
        SwitcherCLIProfileType.Droid => "droid",
        SwitcherCLIProfileType.Forge => "forge",
        SwitcherCLIProfileType.Antigravity => "antigravity",
        SwitcherCLIProfileType.Grok => "grok",
        SwitcherCLIProfileType.CursorAgent => "cursoragent",
        SwitcherCLIProfileType.Omp => "omp",
        SwitcherCLIProfileType.Gemini => "gemini",
        SwitcherCLIProfileType.Kimi => "kimi",
        _ => "pi",
    };

    public static string DisplayName(this SwitcherCLIProfileType type) => type switch
    {
        SwitcherCLIProfileType.Codex => "Codex",
        SwitcherCLIProfileType.Claude => "Claude Code",
        SwitcherCLIProfileType.OpenCode => "OpenCode",
        SwitcherCLIProfileType.Droid => "Droid",
        SwitcherCLIProfileType.Forge => "Forge",
        SwitcherCLIProfileType.Antigravity => "Antigravity",
        SwitcherCLIProfileType.Grok => "Grok Build",
        SwitcherCLIProfileType.CursorAgent => "Cursor Agent",
        SwitcherCLIProfileType.Omp => "OMP",
        SwitcherCLIProfileType.Gemini => "Gemini CLI",
        SwitcherCLIProfileType.Kimi => "Kimi",
        _ => "Pi",
    };

    public static string ExecutableName(this SwitcherCLIProfileType type) => type switch
    {
        SwitcherCLIProfileType.Codex => "codex",
        SwitcherCLIProfileType.Claude => "claude",
        SwitcherCLIProfileType.OpenCode => "opencode",
        SwitcherCLIProfileType.Droid => "droid",
        SwitcherCLIProfileType.Forge => "forge",
        SwitcherCLIProfileType.Antigravity => "agy",
        SwitcherCLIProfileType.Grok => "grok",
        SwitcherCLIProfileType.CursorAgent => "cursor-agent",
        SwitcherCLIProfileType.Omp => "omp",
        SwitcherCLIProfileType.Gemini => "gemini",
        SwitcherCLIProfileType.Kimi => "kimi",
        _ => "pi",
    };

    /// <summary>
    /// Canonical provider drain-target key. Swift: <c>canonicalAgentProvider.providerID.rawValue</c>
    /// (verified arm-by-arm against OpenBurnBarCore AgentProvider.providerID + persistedToken).
    /// This is the per-provider key used in <c>switcher_active_profile</c>.
    /// </summary>
    public static string ProviderKey(this SwitcherCLIProfileType type) => type switch
    {
        SwitcherCLIProfileType.Codex => "codex",
        SwitcherCLIProfileType.Claude => "claude-code",
        SwitcherCLIProfileType.OpenCode => "opencode",
        SwitcherCLIProfileType.Droid => "factory",
        SwitcherCLIProfileType.Forge => "forge",
        SwitcherCLIProfileType.Antigravity => "antigravity",
        SwitcherCLIProfileType.Grok => "xai",
        SwitcherCLIProfileType.CursorAgent => "cursor-agent",
        SwitcherCLIProfileType.Omp => "omp",
        SwitcherCLIProfileType.Gemini => "geminicli",
        SwitcherCLIProfileType.Kimi => "kimi",
        _ => "piagent",
    };
}

/// <summary>
/// A signed-in web service inside a browser profile. Swift: <c>BrowserServiceIdentity</c>.
/// Carries only a provider tag + optional label — never a token.
/// </summary>
public sealed record BrowserServiceIdentity(
    BrowserServiceProvider Provider,
    string? AccountLabel = null)
{
    public string DisplaySummary =>
        string.IsNullOrEmpty(AccountLabel)
            ? $"{Provider.DisplayName()}: signed in"
            : $"{Provider.DisplayName()}: {AccountLabel}";
}

/// <summary>Launch metadata for a browser profile. Swift: <c>SwitcherBrowserProfileMetadata</c>.</summary>
public sealed record SwitcherBrowserProfileMetadata(
    string ProfileIdentifier,
    string? DisplayLabel = null,
    string? AccountEmail = null,
    string? ProviderIdentifier = null,
    IReadOnlyList<BrowserServiceIdentity>? ServiceIdentities = null,
    bool IsDisabled = false)
{
    public IReadOnlyList<BrowserServiceIdentity> ServiceIdentities { get; init; } =
        ServiceIdentities ?? Array.Empty<BrowserServiceIdentity>();
}

/// <summary>Launch metadata for a CLI profile. Swift: <c>SwitcherCLIProfileMetadata</c>.</summary>
public sealed record SwitcherCLIProfileMetadata(
    string? WorkingDirectory = null,
    IReadOnlyList<string>? AdditionalArgs = null,
    IReadOnlyList<string>? EnvKeysToPass = null,
    string? DisplayLabel = null,
    string? ConfigDirectory = null,
    string? AccountDescription = null,
    string? ProviderId = null,
    string? RuntimeAccountId = null,
    string? SubscriptionTierId = null,
    string? ModelCapabilityClassId = null,
    IReadOnlyList<string>? LinkedHarnessIds = null,
    bool NeverAutoSwitch = false,
    DateTimeOffset? LastQuotaExhaustedAt = null,
    DateTimeOffset? ExhaustedUntil = null,
    string? LastQuotaExhaustionDetail = null,
    bool IsDisabled = false)
{
    public IReadOnlyList<string> AdditionalArgs { get; init; } =
        AdditionalArgs ?? Array.Empty<string>();

    public IReadOnlyList<string> EnvKeysToPass { get; init; } =
        EnvKeysToPass ?? Array.Empty<string>();

    public IReadOnlyList<string> LinkedHarnessIds { get; init; } =
        LinkedHarnessIds ?? Array.Empty<string>();
}

/// <summary>
/// A complete launchable identity. Swift: <c>SwitcherProfileRecord</c>. Browser fields are
/// set when <see cref="TargetKind"/> is <see cref="SwitcherProfileTargetKind.Browser"/>; CLI
/// fields when it is <see cref="SwitcherProfileTargetKind.Cli"/>.
/// </summary>
public sealed record SwitcherProfileRecord(
    string Id,
    SwitcherProfileTargetKind TargetKind,
    int SortKey,
    SwitcherBrowserProfileType? BrowserType = null,
    SwitcherBrowserProfileMetadata? BrowserMetadata = null,
    SwitcherCLIProfileType? CliType = null,
    SwitcherCLIProfileMetadata? CliMetadata = null,
    DateTimeOffset CreatedAt = default,
    DateTimeOffset UpdatedAt = default)
{
    /// <summary>Human-readable name. Swift: <c>displayName</c>.</summary>
    public string DisplayName
    {
        get
        {
            if (BrowserMetadata is not null)
            {
                return BrowserMetadata.DisplayLabel ?? BrowserMetadata.ProfileIdentifier;
            }

            if (CliMetadata is not null)
            {
                return CliMetadata.DisplayLabel ?? CliType?.DisplayName() ?? "CLI Profile";
            }

            return "Unknown Profile";
        }
    }

    /// <summary>Concrete target token. Swift: <c>concreteTargetType</c>.</summary>
    public string ConcreteTargetType =>
        BrowserType is { } b ? b.RawValue()
        : CliType is { } c ? c.RawValue()
        : "unknown";

    /// <summary>Swift: <c>isDisabled</c> (delegates to the active metadata).</summary>
    public bool IsDisabled => TargetKind switch
    {
        SwitcherProfileTargetKind.Browser => BrowserMetadata?.IsDisabled ?? false,
        _ => CliMetadata?.IsDisabled ?? false,
    };

    /// <summary>
    /// Normalized name for uniqueness comparison. Swift: <c>SwitcherProfileRecord.normalizeName</c>
    /// (lowercase, trimmed, whitespace collapsed to single spaces).
    /// </summary>
    public static string NormalizeName(string name) =>
        string.Join(
            " ",
            (name ?? string.Empty)
                .ToLowerInvariant()
                .Trim()
                .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}

/// <summary>Current active-profile selection. Swift: <c>SwitcherActiveProfileState</c>.</summary>
public sealed record SwitcherActiveProfileState(
    string? ActiveProfileId,
    DateTimeOffset UpdatedAt = default);
