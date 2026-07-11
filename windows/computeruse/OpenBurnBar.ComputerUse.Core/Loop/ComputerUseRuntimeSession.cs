using System;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Audit;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;

namespace OpenBurnBar.ComputerUse.Core.Loop;

/// <summary>App-owned, audited Computer Use system session over injected platform adapters.</summary>
public sealed class ComputerUseRuntimeSession
{
    private readonly object _gate = new();
    private readonly IUiInspector _inspector;
    private readonly KillSwitchStateMachine _killSwitch;
    private readonly ComputerUseDesktopLoop _desktopLoop;
    private readonly ComputerUseAuditLogger _audit;
    private bool _active = true;

    public ComputerUseRuntimeSession(
        ComputerUseSessionManifest manifest,
        string auditBaseDirectory,
        string appVersion,
        IInputSynthesizer input,
        IUiInspector inspector,
        KillSwitchStateMachine killSwitch)
    {
        Manifest = manifest ?? throw new ArgumentNullException(nameof(manifest));
        _inspector = inspector ?? throw new ArgumentNullException(nameof(inspector));
        _killSwitch = killSwitch ?? throw new ArgumentNullException(nameof(killSwitch));
        _desktopLoop = new ComputerUseDesktopLoop(input, killSwitch);
        _audit = new ComputerUseAuditLogger(manifest.SessionId, auditBaseDirectory, appVersion);
        _audit.BeginSession(manifest);
    }

    public ComputerUseSessionManifest Manifest { get; }

    public string SessionId => Manifest.SessionId;

    public string AuditDirectory => _audit.Directory;

    public bool IsActive
    {
        get
        {
            lock (_gate)
            {
                return _active;
            }
        }
    }

    /// <summary>Requests operator approval, then runs the audited dispatch path.</summary>
    public async Task<ComputerUseLoopResult> RequestApprovalAndDispatchAsync(
        MacInputAction action,
        IDaemonApprovalChannel approvalChannel,
        AuditApprovedBy approvedBy = AuditApprovedBy.Mac,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(action);
        ArgumentNullException.ThrowIfNull(approvalChannel);

        ApprovalDecision decision;
        try
        {
            decision = await approvalChannel
                .RequestApprovalAsync(action, SessionId, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return RecordDenied(action, ComputerUseDenyReason.AuditFailure, ex.GetType().Name);
        }

        return decision.Approved
            ? DispatchAlreadyApproved(action, approvedBy, decision.ApprovalId)
            : RecordDenied(action, ComputerUseDenyReason.UserRejected, decision.ApprovalId);
    }

    /// <summary>Dispatches an action whose capability gate and approval already succeeded.</summary>
    public ComputerUseLoopResult DispatchAlreadyApproved(
        MacInputAction action,
        AuditApprovedBy approvedBy,
        string? approvalId = null)
    {
        ArgumentNullException.ThrowIfNull(action);
        lock (_gate)
        {
            if (!_active)
            {
                return ComputerUseLoopResult.Denied(ComputerUseDenyReason.ConcurrentSession, "session_inactive");
            }

            if (_killSwitch.ShouldBlockDispatch())
            {
                return RecordDeniedLocked(action, ComputerUseDenyReason.KillSwitch, null);
            }

            if (!_desktopLoop.CanRoute(action))
            {
                return RecordDeniedLocked(
                    action,
                    ComputerUseDenyReason.SignatureFailure,
                    "signed_input_driver_required");
            }

            UiElementInfo target;
            try
            {
                target = action.ActionKind == MacInputAction.Kind.PointerClick
                    ? _inspector.InspectCursor()
                    : action.DisplayX is { } x && action.DisplayY is { } y
                    ? _inspector.InspectPoint(x, y)
                    : _inspector.InspectFrontmost();
            }
            catch (Exception ex)
            {
                return RecordDeniedLocked(action, ComputerUseDenyReason.AccessibilityRevoked, ex.GetType().Name);
            }

            if (target.ClassifyDenyRegion() is { } denyRegion)
            {
                return RecordDeniedLocked(action, ComputerUseDenyReason.DenyRegion, denyRegion.ToString());
            }

            try
            {
                ComputerUseAuditEntry entry = _audit.MakeEntry(
                    action,
                    DateTimeOffset.UtcNow,
                    approvedBy,
                    approvalId: approvalId,
                    macHostNodeId: Environment.MachineName,
                    scopeContext: new ScopeContextSummary(bundleId: target.ProcessImageName));
                _audit.Append(entry);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                return RecordDeniedLocked(action, ComputerUseDenyReason.AuditFailure, ex.GetType().Name);
            }

            return _desktopLoop.Dispatch(action);
        }
    }

    public void End()
    {
        lock (_gate)
        {
            _active = false;
        }
    }

    private ComputerUseLoopResult RecordDenied(
        MacInputAction action,
        ComputerUseDenyReason reason,
        string? detail)
    {
        lock (_gate)
        {
            return RecordDeniedLocked(action, reason, detail);
        }
    }

    private ComputerUseLoopResult RecordDeniedLocked(
        MacInputAction action,
        ComputerUseDenyReason reason,
        string? detail)
    {
        if (_active)
        {
            try
            {
                ComputerUseAuditEntry entry = _audit.MakeEntry(
                    action,
                    DateTimeOffset.UtcNow,
                    AuditApprovedBy.Denied,
                    denyReason: reason.ToWire(),
                    macHostNodeId: Environment.MachineName);
                _audit.Append(entry);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                return ComputerUseLoopResult.Denied(ComputerUseDenyReason.AuditFailure, ex.GetType().Name);
            }
        }

        return ComputerUseLoopResult.Denied(reason, detail);
    }
}
