// View-model for the Computer Use settings tab.
//
// Faithful port of AgentLens/Views/ComputerUseSettingsView.swift's settings surface +
// the ComputerUseSessionPanelModel policy state. Reuses the portable Computer Use policy
// core (windows/computeruse/OpenBurnBar.ComputerUse.Core): ComputerUseTrustMode,
// ComputerUseMode, and the built-in deny registry.
//
// Most Computer Use state is transient/runtime, not persisted UserDefaults:
//   selectedTab (setup/policy/forensics), accessibilityTrusted (probe), the audit form
//   (auditSessionId, auditIncludeScreenshots=true, auditAdvancedExpanded=false,
//    auditNotarizationOptIn=false, auditStatus), and the live trust mode (Manual).
// Validation (Swift): Validate/Export enabled when the trimmed session id is non-empty
// and no audit op is running; Notarize additionally requires the notarization opt-in.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.Browser;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.Scope;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>Inner tab of the Computer Use surface (Swift <c>ComputerUseSettingsView.Tab</c>).</summary>
public enum ComputerUseSettingsSection
{
    Setup,
    Policy,
    Forensics,
}

/// <summary>Lifecycle of an audit-chain operation (Swift <c>AuditOperationStatus.Kind</c>).</summary>
public enum AuditOperationKind
{
    Idle,
    Running,
    Succeeded,
    Failed,
}

/// <summary>An audit operation's status (kind + message).</summary>
public sealed record AuditOperationStatus(AuditOperationKind Kind, string Message)
{
    /// <summary>The initial idle status.</summary>
    public static readonly AuditOperationStatus Idle = new(AuditOperationKind.Idle, string.Empty);
}

/// <summary>Result of an audit action seam call.</summary>
public sealed record AuditActionResult(bool Success, string Message)
{
    public static AuditActionResult Ok(string message) => new(true, message);

    public static AuditActionResult Fail(string message) => new(false, message);
}

/// <summary>Runs the audit-chain operations (validate / export / notarize). WinUI-backed; OS/data-bound.</summary>
public interface IComputerUseAuditService
{
    /// <summary>Verify the audit hash-chain for <paramref name="sessionId"/>.</summary>
    AuditActionResult ValidateChain(string sessionId);

    /// <summary>Export the audit archive for <paramref name="sessionId"/>.</summary>
    AuditActionResult ExportArchive(string sessionId, bool includeScreenshots);

    /// <summary>Notarize the audit chain for <paramref name="sessionId"/> (requires opt-in).</summary>
    AuditActionResult Notarize(string sessionId);
}

/// <summary>Deterministic audit service that always succeeds (default for tests).</summary>
public sealed class NoopComputerUseAuditService : IComputerUseAuditService
{
    public AuditActionResult ValidateChain(string sessionId) => AuditActionResult.Ok("Audit chain verified.");

    public AuditActionResult ExportArchive(string sessionId, bool includeScreenshots) =>
        AuditActionResult.Ok("Audit archive exported.");

    public AuditActionResult Notarize(string sessionId) => AuditActionResult.Ok("Audit chain notarized.");
}

/// <summary>Persists the Computer Use permissions-onboarding completion flag.</summary>
public interface IComputerUsePermissionsStore
{
    bool OnboardingCompleted { get; set; }
}

/// <summary>In-memory permissions store (default for tests).</summary>
public sealed class InMemoryComputerUsePermissionsStore : IComputerUsePermissionsStore
{
    public bool OnboardingCompleted { get; set; }
}

public interface IComputerUseBrowserSettingsStore
{
    string BrowserCheckUrl { get; set; }
}

public sealed class InMemoryComputerUseBrowserSettingsStore : IComputerUseBrowserSettingsStore
{
    public string BrowserCheckUrl { get; set; } = "https://example.com";
}

/// <summary>Live fleet safety inputs supplied by Remote Config composition.</summary>
public interface IComputerUseFleetSafetySource
{
    bool IsResolved { get; }
    bool KillSwitchActive { get; }
    bool WatchEnabled { get; }
    bool BrowserEnabled { get; }
    bool SystemEnabled { get; }
    bool PhoneControlEnabled { get; }
    bool TrustModesEnabled { get; }
}

/// <summary>Injectable safety source. Defaults are intentionally fail closed.</summary>
public sealed class DelegatingComputerUseFleetSafetySource : IComputerUseFleetSafetySource
{
    private readonly Func<bool> _isResolved;
    private readonly Func<bool> _killSwitchActive;
    private readonly Func<bool> _watchEnabled;
    private readonly Func<bool> _browserEnabled;
    private readonly Func<bool> _systemEnabled;
    private readonly Func<bool> _phoneControlEnabled;
    private readonly Func<bool> _trustModesEnabled;

    public DelegatingComputerUseFleetSafetySource(
        Func<bool>? isResolved = null,
        Func<bool>? killSwitchActive = null,
        Func<bool>? watchEnabled = null,
        Func<bool>? browserEnabled = null,
        Func<bool>? systemEnabled = null,
        Func<bool>? phoneControlEnabled = null,
        Func<bool>? trustModesEnabled = null)
    {
        _isResolved = isResolved ?? (() => false);
        _killSwitchActive = killSwitchActive ?? (() => true);
        _watchEnabled = watchEnabled ?? (() => false);
        _browserEnabled = browserEnabled ?? (() => false);
        _systemEnabled = systemEnabled ?? (() => false);
        _phoneControlEnabled = phoneControlEnabled ?? (() => false);
        _trustModesEnabled = trustModesEnabled ?? (() => false);
    }

    public bool IsResolved => _isResolved();
    public bool KillSwitchActive => _killSwitchActive();
    public bool WatchEnabled => _watchEnabled();
    public bool BrowserEnabled => _browserEnabled();
    public bool SystemEnabled => _systemEnabled();
    public bool PhoneControlEnabled => _phoneControlEnabled();
    public bool TrustModesEnabled => _trustModesEnabled();
}

/// <summary>Backs the Computer Use tab (readiness, policy trust-mode, and the audit-chain console).</summary>
public sealed class ComputerUseSettingsViewModel : ObservableSettingsViewModel
{
    private readonly IAccessibilityProbe _accessibility;
    private readonly IComputerUseAuditService _audit;
    private readonly IComputerUsePermissionsStore _permissions;
    private readonly IComputerUseBrowserSettingsStore _browserSettings;
    private readonly IComputerUseBrowserService _browser;
    private readonly IComputerUseFleetSafetySource _fleetSafety;
    private readonly Func<DateTimeOffset> _now;

    private ComputerUseSettingsSection _section = ComputerUseSettingsSection.Setup;
    private bool _accessibilityTrusted;
    private ComputerUseTrustMode _liveTrustMode = ComputerUseTrustMode.Manual;
    private bool _isSessionActive;
    private ComputerUseMode _selectedMode = ComputerUseMode.Browser;
    private DateTimeOffset? _sessionStartedAt;

    private string _auditSessionId = string.Empty;
    private bool _auditIncludeScreenshots = true;
    private bool _auditAdvancedExpanded;
    private bool _auditNotarizationOptIn;
    private AuditOperationStatus _auditStatus = AuditOperationStatus.Idle;
    private string _browserCheckUrl;
    private string _browserCheckStatus = string.Empty;
    private bool _browserCheckRunning;

    public ComputerUseSettingsViewModel(
        IAccessibilityProbe? accessibility = null,
        IComputerUseAuditService? audit = null,
        IComputerUsePermissionsStore? permissions = null,
        IComputerUseBrowserSettingsStore? browserSettings = null,
        IComputerUseBrowserService? browser = null,
        IComputerUseFleetSafetySource? fleetSafety = null,
        Func<DateTimeOffset>? now = null)
    {
        _accessibility = accessibility ?? new StaticAccessibilityProbe(false);
        _audit = audit ?? new NoopComputerUseAuditService();
        _permissions = permissions ?? new InMemoryComputerUsePermissionsStore();
        _browserSettings = browserSettings ?? new InMemoryComputerUseBrowserSettingsStore();
        _browser = browser ?? DisabledComputerUseBrowserService.Instance;
        _fleetSafety = fleetSafety ?? new DelegatingComputerUseFleetSafetySource();
        _browserCheckUrl = _browserSettings.BrowserCheckUrl;
        _now = now ?? (() => DateTimeOffset.UtcNow);
        RefreshReadiness();
    }

    /// <summary>Which inner section (setup / policy / forensics) is showing.</summary>
    public ComputerUseSettingsSection Section
    {
        get => _section;
        set => Set(ref _section, value);
    }

    /// <summary>Whether accessibility/UI-automation access is granted.</summary>
    public bool AccessibilityTrusted
    {
        get => _accessibilityTrusted;
        private set
        {
            if (Set(ref _accessibilityTrusted, value))
            {
                OnPropertyChanged(nameof(IsReady));
                OnPropertyChanged(nameof(CanStartSession));
            }
        }
    }

    /// <summary>Whether the tab considers Computer Use ready to run on this machine.</summary>
    public bool IsReady => _accessibilityTrusted && IsSelectedModeFleetEnabled;

    public bool RuntimeSafetyResolved => _fleetSafety.IsResolved;

    public bool FleetKillSwitchActive => !_fleetSafety.IsResolved || _fleetSafety.KillSwitchActive;

    public bool IsSelectedModeFleetEnabled =>
        _fleetSafety.IsResolved
        && !_fleetSafety.KillSwitchActive
        && (SelectedMode switch
        {
            ComputerUseMode.AgentWatch => _fleetSafety.WatchEnabled,
            ComputerUseMode.Browser => _fleetSafety.BrowserEnabled,
            ComputerUseMode.System => _fleetSafety.SystemEnabled,
            _ => false,
        });

    /// <summary>Whether the permissions onboarding has been completed at least once.</summary>
    public bool PermissionsOnboardingCompleted => _permissions.OnboardingCompleted;

    /// <summary>Re-read the OS readiness signals (Swift <c>refreshReadiness</c>).</summary>
    public void RefreshReadiness() => AccessibilityTrusted = _accessibility.IsAccessibilityTrusted;

    public bool BrowserRuntimeAvailable => _browser.IsAvailable;

    public string BrowserRuntimeStatus => _browser.RuntimeStatus;

    public string BrowserCheckUrl
    {
        get => _browserCheckUrl;
        set
        {
            string normalized = value?.Trim() ?? string.Empty;
            if (Set(ref _browserCheckUrl, normalized))
            {
                _browserSettings.BrowserCheckUrl = normalized;
                OnPropertyChanged(nameof(CanRunBrowserCheck));
            }
        }
    }

    public string BrowserCheckStatus
    {
        get => _browserCheckStatus;
        private set => Set(ref _browserCheckStatus, value);
    }

    public bool IsBrowserCheckRunning
    {
        get => _browserCheckRunning;
        private set
        {
            if (Set(ref _browserCheckRunning, value))
            {
                OnPropertyChanged(nameof(CanRunBrowserCheck));
            }
        }
    }

    public bool CanRunBrowserCheck =>
        _fleetSafety.IsResolved
        && !_fleetSafety.KillSwitchActive
        && _fleetSafety.BrowserEnabled
        && _browser.IsAvailable
        && !IsBrowserCheckRunning
        && IsSafeBrowserCheckUrl(BrowserCheckUrl);

    public async Task RunBrowserCheck()
    {
        if (!CanRunBrowserCheck)
        {
            BrowserCheckStatus = _browser.IsAvailable
                ? !_fleetSafety.IsResolved || _fleetSafety.KillSwitchActive || !_fleetSafety.BrowserEnabled
                    ? "Browser Computer Use is disabled by fleet safety policy."
                    : "Enter a public HTTP or HTTPS URL."
                : _browser.RuntimeStatus;
            return;
        }

        IsBrowserCheckRunning = true;
        BrowserCheckStatus = "Checking the managed browser runtime...";
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try
        {
            BrowserSessionResult result = await _browser
                .RunCheckAsync(BrowserCheckUrl, timeout.Token);
            BrowserCheckStatus = result.Succeeded
                ? "Browser runtime check passed."
                : "Browser runtime check failed: " + (result.Error ?? "unknown_error");
        }
        catch (OperationCanceledException)
        {
            BrowserCheckStatus = "Browser runtime check timed out.";
        }
        catch (Exception error)
        {
            BrowserCheckStatus = "Browser runtime check failed: " + error.GetBaseException().Message;
        }
        finally
        {
            IsBrowserCheckRunning = false;
        }
    }

    // ── Policy ────────────────────────────────────────────────────────────────

    /// <summary>The live approval granularity (never sticky; resets to Manual). Core enum.</summary>
    public ComputerUseTrustMode LiveTrustMode
    {
        get => _liveTrustMode;
        set
        {
            if (value != ComputerUseTrustMode.Manual && !_fleetSafety.TrustModesEnabled)
            {
                throw new InvalidOperationException("Fleet safety policy has not enabled elevated trust modes.");
            }
            Set(ref _liveTrustMode, value);
        }
    }

    /// <summary>The available approval granularities.</summary>
    public IReadOnlyList<ComputerUseTrustMode> TrustModeChoices { get; } =
        Enum.GetValues<ComputerUseTrustMode>();

    /// <summary>The available run modes (Agent Watch / Browser / System).</summary>
    public IReadOnlyList<ComputerUseMode> ModeChoices { get; } = Enum.GetValues<ComputerUseMode>();

    public ComputerUseMode SelectedMode
    {
        get => _selectedMode;
        set
        {
            if (Set(ref _selectedMode, value))
            {
                OnPropertyChanged(nameof(IsSelectedModeFleetEnabled));
                OnPropertyChanged(nameof(IsReady));
                OnPropertyChanged(nameof(CanStartSession));
            }
        }
    }

    /// <summary>The built-in protected targets the policy always denies (core deny registry).</summary>
    public IReadOnlyList<ScopeRule> BuiltInDenyRules => DenyRegistry.BuiltInRules;

    /// <summary>Whether a Computer Use session is currently active.</summary>
    public bool IsSessionActive
    {
        get => _isSessionActive;
        private set
        {
            if (Set(ref _isSessionActive, value))
            {
                OnPropertyChanged(nameof(SessionStartedAt));
                OnPropertyChanged(nameof(CanStartSession));
            }
        }
    }

    /// <summary>When the active session started (null when idle).</summary>
    public DateTimeOffset? SessionStartedAt => _sessionStartedAt;

    public bool CanStartSession => IsReady && !IsSessionActive;

    /// <summary>Start a Computer Use session (records the start time from the injected clock).</summary>
    public void StartSession()
    {
        if (_isSessionActive)
        {
            return;
        }
        if (!IsReady)
        {
            throw new InvalidOperationException("Computer Use is blocked by permissions or fleet safety policy.");
        }

        _sessionStartedAt = _now();
        IsSessionActive = true;
    }

    /// <summary>End the active session.</summary>
    public void EndSession()
    {
        if (!_isSessionActive)
        {
            return;
        }

        _sessionStartedAt = null;
        IsSessionActive = false;
    }

    // ── Audit-chain forensics ─────────────────────────────────────────────────

    /// <summary>The audit session id to verify / export / notarize.</summary>
    public string AuditSessionId
    {
        get => _auditSessionId;
        set { if (Set(ref _auditSessionId, value ?? string.Empty)) { RaiseAuditValidation(); } }
    }

    /// <summary>Whether an export includes screenshots.</summary>
    public bool AuditIncludeScreenshots
    {
        get => _auditIncludeScreenshots;
        set => Set(ref _auditIncludeScreenshots, value);
    }

    /// <summary>Whether the advanced audit controls are expanded.</summary>
    public bool AuditAdvancedExpanded
    {
        get => _auditAdvancedExpanded;
        set => Set(ref _auditAdvancedExpanded, value);
    }

    /// <summary>Whether the operator opted into notarization.</summary>
    public bool AuditNotarizationOptIn
    {
        get => _auditNotarizationOptIn;
        set { if (Set(ref _auditNotarizationOptIn, value)) { OnPropertyChanged(nameof(CanNotarize)); } }
    }

    /// <summary>The current audit-op status.</summary>
    public AuditOperationStatus AuditStatus
    {
        get => _auditStatus;
        private set
        {
            if (Set(ref _auditStatus, value))
            {
                RaiseAuditValidation();
            }
        }
    }

    /// <summary>The trimmed session id (Swift <c>trimmedAuditSessionId</c>).</summary>
    public string TrimmedAuditSessionId => _auditSessionId.Trim();

    /// <summary>Whether an audit operation is in flight.</summary>
    public bool IsAuditRunning => _auditStatus.Kind == AuditOperationKind.Running;

    /// <summary>Whether Validate Chain is enabled.</summary>
    public bool CanValidateChain => TrimmedAuditSessionId.Length > 0 && !IsAuditRunning;

    /// <summary>Whether Export Archive is enabled.</summary>
    public bool CanExportArchive => TrimmedAuditSessionId.Length > 0 && !IsAuditRunning;

    /// <summary>Whether Notarize is enabled (needs the opt-in too).</summary>
    public bool CanNotarize => CanValidateChain && _auditNotarizationOptIn;

    /// <summary>Validate the audit hash-chain (Swift <c>validateAuditChain</c>).</summary>
    public void ValidateChain()
    {
        if (!CanValidateChain)
        {
            return;
        }

        RunAudit(() => _audit.ValidateChain(TrimmedAuditSessionId));
    }

    /// <summary>Export the audit archive (Swift <c>exportAuditArchive</c>).</summary>
    public void ExportArchive()
    {
        if (!CanExportArchive)
        {
            return;
        }

        RunAudit(() => _audit.ExportArchive(TrimmedAuditSessionId, _auditIncludeScreenshots));
    }

    /// <summary>Notarize the audit chain via OTS (Swift <c>notarizeAuditChain</c>).</summary>
    public void Notarize()
    {
        if (!CanNotarize)
        {
            return;
        }

        RunAudit(() => _audit.Notarize(TrimmedAuditSessionId));
    }

    /// <summary>Complete (or re-run) the Mac permissions setup — records the onboarding flag.</summary>
    public void CompletePermissionsSetup()
    {
        _permissions.OnboardingCompleted = true;
        OnPropertyChanged(nameof(PermissionsOnboardingCompleted));
    }

    private void RunAudit(Func<AuditActionResult> operation)
    {
        AuditStatus = new AuditOperationStatus(AuditOperationKind.Running, "Working…");
        var result = operation();
        AuditStatus = result.Success
            ? new AuditOperationStatus(AuditOperationKind.Succeeded, result.Message)
            : new AuditOperationStatus(AuditOperationKind.Failed, result.Message);
    }

    private void RaiseAuditValidation()
    {
        OnPropertyChanged(nameof(TrimmedAuditSessionId));
        OnPropertyChanged(nameof(IsAuditRunning));
        OnPropertyChanged(nameof(CanValidateChain));
        OnPropertyChanged(nameof(CanExportArchive));
        OnPropertyChanged(nameof(CanNotarize));
    }

    internal static bool IsSafeBrowserCheckUrl(string value)
    {
        if (value.Length > BrowserComputerUseLifecycle.MaxUrlCharacters
            || !Uri.TryCreate(value, UriKind.Absolute, out Uri? uri)
            || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
            || !string.IsNullOrEmpty(uri.UserInfo)
            || IsKnownInternalHost(uri.Host))
        {
            return false;
        }

        return !IPAddress.TryParse(uri.Host, out IPAddress? address) || IsPublicAddress(address);
    }

    private static bool IsKnownInternalHost(string host) =>
        host.Equals("localhost", StringComparison.OrdinalIgnoreCase)
        || host.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase)
        || host.Equals("metadata", StringComparison.OrdinalIgnoreCase)
        || host.Equals("metadata.google.internal", StringComparison.OrdinalIgnoreCase)
        || host.EndsWith(".metadata.google.internal", StringComparison.OrdinalIgnoreCase);

    private static bool IsPublicAddress(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6)
        {
            address = address.MapToIPv4();
        }

        if (IPAddress.IsLoopback(address)
            || address.IsIPv6LinkLocal
            || address.IsIPv6SiteLocal
            || address.IsIPv6Multicast)
        {
            return false;
        }

        byte[] bytes = address.GetAddressBytes();
        if (bytes.Length != 4)
        {
            return !address.Equals(IPAddress.IPv6Any) && !address.Equals(IPAddress.IPv6None);
        }

        int first = bytes[0];
        int second = bytes[1];
        return first != 0
            && first != 10
            && first != 127
            && !(first == 100 && second is >= 64 and <= 127)
            && !(first == 169 && second == 254)
            && !(first == 172 && second is >= 16 and <= 31)
            && !(first == 192 && second == 168)
            && !(first == 198 && second is 18 or 19)
            && first < 224;
    }
}
