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

/// <summary>Backs the Computer Use tab (readiness, policy trust-mode, and the audit-chain console).</summary>
public sealed class ComputerUseSettingsViewModel : ObservableSettingsViewModel
{
    private readonly IAccessibilityProbe _accessibility;
    private readonly IComputerUseAuditService _audit;
    private readonly IComputerUsePermissionsStore _permissions;
    private readonly Func<DateTimeOffset> _now;

    private ComputerUseSettingsSection _section = ComputerUseSettingsSection.Setup;
    private bool _accessibilityTrusted;
    private ComputerUseTrustMode _liveTrustMode = ComputerUseTrustMode.Manual;
    private bool _isSessionActive;
    private DateTimeOffset? _sessionStartedAt;

    private string _auditSessionId = string.Empty;
    private bool _auditIncludeScreenshots = true;
    private bool _auditAdvancedExpanded;
    private bool _auditNotarizationOptIn;
    private AuditOperationStatus _auditStatus = AuditOperationStatus.Idle;

    public ComputerUseSettingsViewModel(
        IAccessibilityProbe? accessibility = null,
        IComputerUseAuditService? audit = null,
        IComputerUsePermissionsStore? permissions = null,
        Func<DateTimeOffset>? now = null)
    {
        _accessibility = accessibility ?? new StaticAccessibilityProbe(false);
        _audit = audit ?? new NoopComputerUseAuditService();
        _permissions = permissions ?? new InMemoryComputerUsePermissionsStore();
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
        private set { if (Set(ref _accessibilityTrusted, value)) { OnPropertyChanged(nameof(IsReady)); } }
    }

    /// <summary>Whether the tab considers Computer Use ready to run on this machine.</summary>
    public bool IsReady => _accessibilityTrusted;

    /// <summary>Whether the permissions onboarding has been completed at least once.</summary>
    public bool PermissionsOnboardingCompleted => _permissions.OnboardingCompleted;

    /// <summary>Re-read the OS readiness signals (Swift <c>refreshReadiness</c>).</summary>
    public void RefreshReadiness() => AccessibilityTrusted = _accessibility.IsAccessibilityTrusted;

    // ── Policy ────────────────────────────────────────────────────────────────

    /// <summary>The live approval granularity (never sticky; resets to Manual). Core enum.</summary>
    public ComputerUseTrustMode LiveTrustMode
    {
        get => _liveTrustMode;
        set => Set(ref _liveTrustMode, value);
    }

    /// <summary>The available approval granularities.</summary>
    public IReadOnlyList<ComputerUseTrustMode> TrustModeChoices { get; } =
        Enum.GetValues<ComputerUseTrustMode>();

    /// <summary>The available run modes (Agent Watch / Browser / System).</summary>
    public IReadOnlyList<ComputerUseMode> ModeChoices { get; } = Enum.GetValues<ComputerUseMode>();

    /// <summary>The built-in protected targets the policy always denies (core deny registry).</summary>
    public IReadOnlyList<ScopeRule> BuiltInDenyRules => DenyRegistry.BuiltInRules;

    /// <summary>Whether a Computer Use session is currently active.</summary>
    public bool IsSessionActive
    {
        get => _isSessionActive;
        private set { if (Set(ref _isSessionActive, value)) { OnPropertyChanged(nameof(SessionStartedAt)); } }
    }

    /// <summary>When the active session started (null when idle).</summary>
    public DateTimeOffset? SessionStartedAt => _sessionStartedAt;

    /// <summary>Start a Computer Use session (records the start time from the injected clock).</summary>
    public void StartSession()
    {
        if (_isSessionActive)
        {
            return;
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
}
