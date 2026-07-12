// Parity source: AgentLens/Services/Cast/CastWizardModel.swift (Step enum + user intents)

using System;
using System.Collections.Generic;
using OpenBurnBar.Integrations.Cast.Model;
using OpenBurnBar.Integrations.Cast.Session;

namespace OpenBurnBar.Integrations.Cast.Wizard;

/// <summary>One state of the Setup Cast Wizard. Port of Swift <c>CastWizardModel.Step</c>.</summary>
public abstract record CastWizardStep
{
    private CastWizardStep()
    {
    }

    /// <summary>Intro screen.</summary>
    public sealed record Welcome : CastWizardStep;

    /// <summary>Scanning for devices.</summary>
    public sealed record Discover : CastWizardStep;

    /// <summary>Scan finished with nothing found.</summary>
    public sealed record NoDevices : CastWizardStep;

    /// <summary>Choose from the discovered devices.</summary>
    public sealed record Pick : CastWizardStep;

    /// <summary>Casting a test pattern to <see cref="Device"/>.</summary>
    public sealed record Testing(CastDevice Device) : CastWizardStep;

    /// <summary>Auto-recovery in progress after a failed attempt.</summary>
    public sealed record Recover(CastDevice Device, int Attempt, string LastError) : CastWizardStep;

    /// <summary>Awaiting the user's confirmation that the test pattern appeared.</summary>
    public sealed record Confirm(CastDevice Device) : CastWizardStep;

    /// <summary>Terminal failure with a reason.</summary>
    public sealed record Failed(string Reason) : CastWizardStep;

    /// <summary>Selection saved for <see cref="Device"/> — the wizard is done.</summary>
    public sealed record Done(CastDevice Device) : CastWizardStep;
}

/// <summary>
/// The values <c>confirmTestPattern()</c> writes back to settings when the user
/// confirms a device, captured as a plain output object so the pure state
/// machine never touches a settings store.
/// </summary>
public sealed record CastSelection
{
    /// <summary>The confirmed device.</summary>
    public required CastDevice Device { get; init; }

    /// <summary>The bridge dashboard URL that was auto-filled, if one was configured.</summary>
    public string? DashboardUrl { get; init; }
}

/// <summary>
/// Pure state machine driving the Setup Cast Wizard. It owns only the step +
/// device list; the view-model performs discovery / cast IO and feeds results
/// back through these intents. Faithful to <c>CastWizardModel</c>.
/// </summary>
public sealed class CastWizardStateMachine
{
    /// <summary>Current wizard step.</summary>
    public CastWizardStep Step { get; private set; } = new CastWizardStep.Welcome();

    /// <summary>The most recently published device list.</summary>
    public IReadOnlyList<CastDevice> Devices { get; private set; } = Array.Empty<CastDevice>();

    /// <summary>Begin discovery (from Welcome or a restart). Clears the device list.</summary>
    public void Start()
    {
        Step = new CastWizardStep.Discover();
        Devices = Array.Empty<CastDevice>();
    }

    /// <summary>Restart discovery — identical to <see cref="Start"/> here.</summary>
    public void RetryDiscovery() => Start();

    /// <summary>
    /// Publish a fresh device list from the browser. Advances Discover/NoDevices
    /// to Pick as soon as anything is found. Port of <c>handleDiscoveredDevices</c>.
    /// </summary>
    public void DevicesDiscovered(IReadOnlyList<CastDevice> devices)
    {
        Devices = devices ?? throw new ArgumentNullException(nameof(devices));
        if (devices.Count == 0)
        {
            return;
        }

        if (Step is CastWizardStep.Discover or CastWizardStep.NoDevices)
        {
            Step = new CastWizardStep.Pick();
        }
    }

    /// <summary>
    /// The 10s discovery timeout fired: if still discovering with nothing found,
    /// show the "no devices" screen. Port of the <c>noDevicesTimeoutTask</c>.
    /// </summary>
    public void DiscoveryTimedOut()
    {
        if (Step is CastWizardStep.Discover && Devices.Count == 0)
        {
            Step = new CastWizardStep.NoDevices();
        }
    }

    /// <summary>
    /// Begin casting a test pattern to a chosen device. If the Smart Display
    /// bridge URL is not configured, fail immediately (port of <c>pickDevice</c>'s
    /// guard).
    /// </summary>
    public void BeginTest(CastDevice device, bool bridgeUrlConfigured)
    {
        if (device is null)
        {
            throw new ArgumentNullException(nameof(device));
        }

        if (!bridgeUrlConfigured)
        {
            Step = new CastWizardStep.Failed("Smart Display bridge URL is not configured.");
            return;
        }

        Step = new CastWizardStep.Testing(device);
    }

    /// <summary>
    /// Feed the outcome of the cast+recovery flow while in the Testing step.
    /// Success / Home-Assistant recovery → Confirm; failure → Recover.
    /// </summary>
    public void ApplyCastResult(CastRecoveryResult result)
    {
        if (result is null)
        {
            throw new ArgumentNullException(nameof(result));
        }

        if (Step is not CastWizardStep.Testing testing)
        {
            return;
        }

        switch (result.Kind)
        {
            case CastRecoveryResultKind.Success:
            case CastRecoveryResultKind.RecoveredViaHomeAssistant:
                Step = new CastWizardStep.Confirm(testing.Device);
                break;
            case CastRecoveryResultKind.Failure:
                Step = new CastWizardStep.Recover(
                    testing.Device,
                    result.AttemptsMade,
                    result.Message ?? "Unknown");
                break;
        }
    }

    /// <summary>Retry the device that is currently in the Recover step (re-enter Testing).</summary>
    public CastDevice? RetryDevice()
    {
        if (Step is not CastWizardStep.Recover recover)
        {
            return null;
        }

        Step = new CastWizardStep.Testing(recover.Device);
        return recover.Device;
    }

    /// <summary>Go back to the device picker.</summary>
    public void TryAnother() => Step = new CastWizardStep.Pick();

    /// <summary>
    /// Confirm the test pattern: produce the <see cref="CastSelection"/> to
    /// persist and advance to Done. Returns <see langword="null"/> if not in the
    /// Confirm step. Port of <c>confirmTestPattern</c>.
    /// </summary>
    public CastSelection? ConfirmTestPattern(string? dashboardUrl)
    {
        if (Step is not CastWizardStep.Confirm confirm)
        {
            return null;
        }

        Step = new CastWizardStep.Done(confirm.Device);
        return new CastSelection
        {
            Device = confirm.Device,
            DashboardUrl = dashboardUrl,
        };
    }

    /// <summary>Cancel the wizard and return to Welcome.</summary>
    public void Cancel()
    {
        Step = new CastWizardStep.Welcome();
        Devices = Array.Empty<CastDevice>();
    }
}
