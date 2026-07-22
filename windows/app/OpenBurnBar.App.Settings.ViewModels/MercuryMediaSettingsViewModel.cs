using System;
using OpenBurnBar.Integrations.Mercury.Budget;
using OpenBurnBar.Integrations.Mercury.Sessions;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>Read-only inputs used by the Mercury settings capability projection.</summary>
public interface IMercuryMediaCapabilitySource
{
    MediaEntitlementState Entitlement { get; }

    MediaBudgetStatus Budget { get; }

    MediaQuotaUsageSnapshot Usage { get; }

    bool KillSwitchActive { get; }

    int ConcurrentSessions { get; }

    bool CaptureRuntimeSupported { get; }
}

/// <summary>
/// Injectable source for tests and for the Windows composition root. The
/// default is deliberately entitlement-off and budget-closed; a missing cloud
/// document or capture permission can never turn into an allowed session.
/// </summary>
public sealed class StaticMercuryMediaCapabilitySource : IMercuryMediaCapabilitySource
{
    public StaticMercuryMediaCapabilitySource(
        MediaEntitlementState? entitlement = null,
        MediaBudgetStatus? budget = null,
        MediaQuotaUsageSnapshot? usage = null,
        bool killSwitchActive = false,
        int concurrentSessions = 0,
        bool? captureRuntimeSupported = null)
    {
        Entitlement = entitlement ?? MediaEntitlementState.None;
        Budget = budget ?? MediaBudgetStatusStore.ConservativeClosed;
        Usage = usage ?? new MediaQuotaUsageSnapshot();
        KillSwitchActive = killSwitchActive;
        ConcurrentSessions = Math.Max(0, concurrentSessions);
        CaptureRuntimeSupported = captureRuntimeSupported ?? OperatingSystem.IsWindows();
    }

    public MediaEntitlementState Entitlement { get; }

    public MediaBudgetStatus Budget { get; }

    public MediaQuotaUsageSnapshot Usage { get; }

    public bool KillSwitchActive { get; }

    public int ConcurrentSessions { get; }

    public bool CaptureRuntimeSupported { get; }
}

/// <summary>Wraps a conservative static source with a live fleet kill-switch projection.</summary>
public sealed class FleetAwareMercuryMediaCapabilitySource : IMercuryMediaCapabilitySource
{
    private readonly IMercuryMediaCapabilitySource _inner;
    private readonly Func<bool> _killSwitchActive;

    public FleetAwareMercuryMediaCapabilitySource(
        Func<bool> killSwitchActive,
        IMercuryMediaCapabilitySource? inner = null)
    {
        _killSwitchActive = killSwitchActive ?? throw new ArgumentNullException(nameof(killSwitchActive));
        _inner = inner ?? new StaticMercuryMediaCapabilitySource(killSwitchActive: true);
    }

    public MediaEntitlementState Entitlement => _inner.Entitlement;
    public MediaBudgetStatus Budget => _inner.Budget;
    public MediaQuotaUsageSnapshot Usage => _inner.Usage;
    public bool KillSwitchActive => _killSwitchActive();
    public int ConcurrentSessions => _inner.ConcurrentSessions;
    public bool CaptureRuntimeSupported => _inner.CaptureRuntimeSupported;
}

/// <summary>
/// Mercury settings projection. It owns admission checks only; actual capture,
/// encoding, transport, and transfer are separate runtime services. Every
/// check uses the same fail-closed evaluator as the media session coordinator.
/// </summary>
public sealed class MercuryMediaSettingsViewModel : ObservableSettingsViewModel
{
    private readonly IMercuryMediaCapabilitySource _source;
    private readonly MediaCapabilityEvaluator _evaluator;
    private MediaFeature _selectedFeature = MediaFeature.ScreenShare;
    private int _requestedDurationSeconds = 60;
    private string _decisionText = "No capability check has been requested.";
    private MediaCapabilityCheck? _lastCheck;

    public MercuryMediaSettingsViewModel(
        IMercuryMediaCapabilitySource? source = null,
        MediaCapabilityEvaluator? evaluator = null)
    {
        _source = source ?? new StaticMercuryMediaCapabilitySource();
        _evaluator = evaluator ?? new MediaCapabilityEvaluator();
        RefreshCapability();
    }

    public MediaFeature SelectedFeature
    {
        get => _selectedFeature;
        set
        {
            if (Set(ref _selectedFeature, value))
            {
                RefreshCapability();
            }
        }
    }

    public int RequestedDurationSeconds
    {
        get => _requestedDurationSeconds;
        set
        {
            if (value is < 1 or > 86_400)
            {
                throw new ArgumentOutOfRangeException(nameof(value), "Duration must be between 1 and 86400 seconds.");
            }

            if (Set(ref _requestedDurationSeconds, value))
            {
                RefreshCapability();
            }
        }
    }

    public bool CaptureRuntimeSupported => _source.CaptureRuntimeSupported;

    public bool EntitlementActive => _source.Entitlement.Active;

    public bool FileTransferEntitled => _source.Entitlement.FileTransfer;

    public bool ScreenShareEntitled => _source.Entitlement.ScreenShare;

    public bool VideoCallEntitled => _source.Entitlement.VideoCall;

    public bool KillSwitchActive => _source.KillSwitchActive;

    public string BudgetLevel => MediaBudgetLevelWire.ToWire(_source.Budget.Level);

    public string DecisionText => _decisionText;

    public bool HasAllowedCapability => _lastCheck?.IsAllowed == true && CaptureRuntimeSupported;

    public string DenialReason => _lastCheck?.DenialReason?.ToString() ?? string.Empty;

    public string Summary => !CaptureRuntimeSupported
        ? "Windows media capture is unavailable on this host."
        : !EntitlementActive
            ? "Mercury is waiting for an authenticated media entitlement."
            : "Mercury admission is governed by entitlement, budget, quota, and the kill switch.";

    /// <summary>Re-evaluate admission for the selected feature.</summary>
    public void RefreshCapability()
    {
        _lastCheck = Evaluate();
        _decisionText = FormatDecision(_lastCheck.Value);
        OnPropertyChanged(nameof(DecisionText));
        OnPropertyChanged(nameof(DenialReason));
        OnPropertyChanged(nameof(HasAllowedCapability));
        OnPropertyChanged(nameof(Summary));
    }

    /// <summary>Explicit command used by the settings host and keyboard flows.</summary>
    public void CheckSelectedCapability() => RefreshCapability();

    private MediaCapabilityCheck Evaluate() => _evaluator.Evaluate(
        _selectedFeature,
        _requestedDurationSeconds,
        sessionByteBudget: null,
        transferDirection: _selectedFeature == MediaFeature.FileTransfer
            ? MediaCapabilityTransferDirection.Outbound
            : null,
        entitlement: _source.Entitlement,
        budget: _source.Budget,
        usage: _source.Usage,
        killSwitchActive: _source.KillSwitchActive,
        concurrentSessions: _source.ConcurrentSessions);

    private string FormatDecision(MediaCapabilityCheck check)
    {
        if (!check.IsAllowed)
        {
            return "Blocked: " + (check.DenialReason?.ToString() ?? "Unknown");
        }

        if (!CaptureRuntimeSupported)
        {
            return "Admission passed, but the Windows capture runtime is unavailable.";
        }

        MediaCapabilityEnvelope envelope = check.Envelope!;
        return envelope.RemainingSecondsToday is { } seconds
            ? $"Allowed for {_selectedFeature}; {seconds} seconds remain today."
            : $"Allowed for {_selectedFeature}; file-transfer byte quota remains server-governed.";
    }
}
