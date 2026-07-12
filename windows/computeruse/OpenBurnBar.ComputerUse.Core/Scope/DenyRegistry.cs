// Hard-coded deny defaults every Computer-Use session inherits.
//
// Port of ComputerUseDenyRegistry.swift, preserving the threat-model coverage
// (master plan § F.1) with Windows-faithful process targets:
//
//   * The macOS auth-surface denies (loginwindow / SecurityAgent / Keychain /
//     Privacy pane / FileVault recovery) map to their Windows secure-surface
//     analogs — LogonUI (lock/login), consent (UAC elevation), CredentialUIBroker
//     (Windows Hello / credential prompt), and the Windows Security / Credential
//     Manager apps. `BundleId` carries the Windows process image name; the
//     matcher's exact/prefix match works identically.
//   * The URL / network denies (OAuth authorize endpoints, file://, localhost,
//     loopback, link-local, cloud metadata, /admin, /billing) are
//     platform-independent and ported VERBATIM.
//
// These rules are never editable/removable through the UI; the editor refuses a
// save that would unmask any of them (see ScopeMatcher.OverlapsBuiltInDeny).

using System;
using System.Collections.Generic;

namespace OpenBurnBar.ComputerUse.Core.Scope;

/// <summary>The built-in, non-removable deny defaults + editor overlap probes.</summary>
public static class DenyRegistry
{
    /// <summary>The built-in deny rules seeded into every session's scope set.</summary>
    public static IReadOnlyList<ScopeRule> BuiltInRules { get; } = new[]
    {
        // ── Windows secure-surface process denies (secure-desktop / auth) ──
        Deny("builtin.logonui", "Windows lock / login screen (LogonUI)", bundleId: "LogonUI.exe"),
        Deny("builtin.uac_consent", "Windows UAC elevation prompt (consent)", bundleId: "consent.exe"),
        Deny("builtin.credential_broker", "Windows Hello / credential prompt (CredentialUIBroker)", bundleId: "CredentialUIBroker.exe"),
        Deny("builtin.credential_uihost", "Windows credential UI host (CredentialUIBroker host)", bundleId: "credwiz.exe"),
        Deny("builtin.windows_security", "Windows Security app", bundleId: "SecHealthUI.exe"),
        Deny("builtin.settings_privacy", "Windows Settings → Privacy & Security", bundleId: "SystemSettings.exe", windowTitleRegex: ".*Privacy.*security.*"),
        Deny("builtin.terminal_admin", "Terminal / console running elevated", bundleId: "WindowsTerminal.exe", windowTitleRegex: ".*Administrator.*"),
        Deny("builtin.mail_send", "Mail \"Send\" (until per-app review)", bundleId: "olk.exe", windowTitleRegex: ".*Send.*"),

        // ── Platform-independent URL / network denies (verbatim) ──
        Deny("builtin.oauth_authorize", "OAuth authorize endpoint", urlPrefix: "https://accounts.google.com/o/oauth2"),
        Deny("builtin.github_oauth", "GitHub OAuth authorize endpoint", urlPrefix: "https://github.com/login/oauth/authorize"),
        Deny("builtin.browser_file_url", "Browser file URLs", urlPrefix: "file://"),
        Deny("builtin.browser_localhost_http", "Browser localhost HTTP", urlPrefix: "http://localhost"),
        Deny("builtin.browser_localhost_https", "Browser localhost HTTPS", urlPrefix: "https://localhost"),
        Deny("builtin.browser_loopback_ipv4_http", "Browser loopback IPv4 HTTP", urlPrefix: "http://127."),
        Deny("builtin.browser_loopback_ipv4_https", "Browser loopback IPv4 HTTPS", urlPrefix: "https://127."),
        Deny("builtin.browser_loopback_ipv6_http", "Browser loopback IPv6 HTTP", urlPrefix: "http://[::1]"),
        Deny("builtin.browser_loopback_ipv6_https", "Browser loopback IPv6 HTTPS", urlPrefix: "https://[::1]"),
        Deny("builtin.browser_link_local_http", "Browser link-local HTTP", urlPrefix: "http://169.254."),
        Deny("builtin.browser_link_local_https", "Browser link-local HTTPS", urlPrefix: "https://169.254."),
        Deny("builtin.browser_google_metadata_http", "Google metadata endpoint HTTP", urlPrefix: "http://metadata.google.internal"),
        Deny("builtin.browser_google_metadata_https", "Google metadata endpoint HTTPS", urlPrefix: "https://metadata.google.internal"),
        Deny("builtin.admin_paths", "URLs containing /admin", windowTitleRegex: ".*/admin.*"),
        Deny("builtin.billing_paths", "URLs containing /billing", windowTitleRegex: ".*/billing.*"),
    };

    /// <summary>True iff <paramref name="id"/> names a built-in (non-editable) rule.</summary>
    public static bool IsBuiltIn(string id)
    {
        foreach (var rule in BuiltInRules)
        {
            if (string.Equals(rule.Id, id, StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>Sample contexts the editor probes to refuse an allow that unmasks a deny.</summary>
    public static IReadOnlyList<ScopeContext> EditorOverlapProbes { get; } = new[]
    {
        new ScopeContext(bundleId: "LogonUI.exe", windowTitle: "Sign in"),
        new ScopeContext(bundleId: "consent.exe", windowTitle: "User Account Control"),
        new ScopeContext(bundleId: "CredentialUIBroker.exe", windowTitle: "Windows Security"),
        new ScopeContext(bundleId: "SystemSettings.exe", windowTitle: "Privacy & security"),
        new ScopeContext(url: "https://accounts.google.com/o/oauth2/v2/auth?...", bundleId: "chrome.exe"),
        new ScopeContext(url: "file:///C:/Windows/System32/config/SAM", bundleId: "chrome.exe"),
        new ScopeContext(url: "http://127.0.0.1:11434/api/tags", bundleId: "chrome.exe"),
        new ScopeContext(url: "http://metadata.google.internal/computeMetadata/v1", bundleId: "chrome.exe"),
    };

    // A rule with a stable createdAt (epoch) so built-in defaults are deterministic
    // and always lose newest-wins ties to a freshly added user rule.
    private static ScopeRule Deny(
        string id,
        string label,
        string? urlPrefix = null,
        string? bundleId = null,
        string? windowTitleRegex = null)
        => new(
            id: id,
            effect: ScopeEffect.Deny,
            origin: ScopeOrigin.BuiltIn,
            label: label,
            urlPrefix: urlPrefix,
            bundleId: bundleId,
            windowTitleRegex: windowTitleRegex,
            createdAt: DateTimeOffset.FromUnixTimeMilliseconds(0));
}

/// <summary>
/// Fast-reject reason from a UIA point probe: the target is a password edit
/// control, a secure-desktop/UAC sheet, or a Windows Hello / credential prompt —
/// even when the rule set itself would have allowed the host process.
/// </summary>
public enum AccessibilityDenyReason
{
    /// <summary>A password / secure text edit control (UIA IsPassword).</summary>
    SecureTextField,

    /// <summary>A system auth / UAC secure-desktop sheet.</summary>
    SystemAuthSheet,

    /// <summary>A Windows Hello / credential-manager prompt.</summary>
    KeychainPrompt,

    /// <summary>Unclassified — fail closed and treat as a deny region.</summary>
    Unknown,
}

/// <summary>Wire strings for <see cref="AccessibilityDenyReason"/> (match the Swift core).</summary>
public static class AccessibilityDenyReasonWire
{
    public static string ToWire(this AccessibilityDenyReason reason) => reason switch
    {
        AccessibilityDenyReason.SecureTextField => "secure_text_field",
        AccessibilityDenyReason.SystemAuthSheet => "system_auth_sheet",
        AccessibilityDenyReason.KeychainPrompt => "keychain_prompt",
        AccessibilityDenyReason.Unknown => "unknown",
        _ => throw new ArgumentOutOfRangeException(nameof(reason), reason, null),
    };
}
