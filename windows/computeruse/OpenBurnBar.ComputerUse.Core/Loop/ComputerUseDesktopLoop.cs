using System;
using OpenBurnBar.ComputerUse.Core.Adapters;
using OpenBurnBar.ComputerUse.Core.Gate;
using OpenBurnBar.ComputerUse.Core.KillSwitch;

namespace OpenBurnBar.ComputerUse.Core.Loop;

/// <summary>
/// Production desktop Computer Use dispatch step: kill-switch leaf check → input
/// synthesis. Callers run <see cref="DefaultComputerUseCapabilityGate.Check"/> first
/// and only invoke this when allowed. Windows injects
/// <c>SendInputInputSynthesizer</c>; tests inject fakes.
/// </summary>
public sealed class ComputerUseDesktopLoop
{
    private readonly IInputSynthesizer _input;
    private readonly KillSwitchStateMachine _killSwitch;

    public ComputerUseDesktopLoop(IInputSynthesizer input, KillSwitchStateMachine killSwitch)
    {
        _input = input ?? throw new ArgumentNullException(nameof(input));
        _killSwitch = killSwitch ?? throw new ArgumentNullException(nameof(killSwitch));
    }

    /// <summary>Whether the configured adapter satisfies this action's integrity route.</summary>
    public bool CanRoute(MacInputAction action) =>
        !action.RequiresSignedDriver || _input.RoutesThroughSignedDriver;

    /// <summary>
    /// Dispatch one already-approved input action through the production path.
    /// </summary>
    public ComputerUseLoopResult Dispatch(MacInputAction action)
    {
        ArgumentNullException.ThrowIfNull(action);

        if (_killSwitch.ShouldBlockDispatch())
        {
            return ComputerUseLoopResult.Denied(ComputerUseDenyReason.KillSwitch);
        }

        if (!CanRoute(action))
        {
            return ComputerUseLoopResult.Denied(
                ComputerUseDenyReason.SignatureFailure,
                "signed_input_driver_required");
        }

        InputSynthesisResult result = _input.Synthesize(action);
        if (!result.Dispatched)
        {
            return ComputerUseLoopResult.Denied(ComputerUseDenyReason.AuditFailure, result.Detail);
        }

        return ComputerUseLoopResult.Ok(result.Detail);
    }

    /// <summary>Convenience: click at display coordinates.</summary>
    public ComputerUseLoopResult Click(int displayX, int displayY) =>
        Dispatch(new MacInputAction(MacInputAction.Kind.Click, displayX: displayX, displayY: displayY));
}

public sealed record ComputerUseLoopResult(bool Succeeded, ComputerUseDenyReason? DenyReason, string? Detail)
{
    public static ComputerUseLoopResult Ok(string? detail = null) => new(true, null, detail);

    public static ComputerUseLoopResult Denied(ComputerUseDenyReason reason, string? detail = null) =>
        new(false, reason, detail);
}
