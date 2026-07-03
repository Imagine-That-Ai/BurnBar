// PORTED (portable, unit-tested) from
//   AgentLens/Views/Onboarding/HermesSetupWizardController.swift
//     enum HermesSetupStep, enum GatewayReachabilityState/Accent, and the
//     controller's derived reachability + step-gating rules.
//
// The reachability DERIVATION and the step-gating are the parity-critical logic
// (they decide the Connect hero's copy + which Continue buttons enable). They are
// separated here (System-only, NO WinUI) so they are asserted by a real `dotnet test`.
// The live probe/config I/O (gateway launch, ~/.hermes/.env) is injected through
// IHermesSetupActions on Windows; the model owns none of it — exactly like the Swift
// controller funnels everything through HermesSetupWizardDependencies.

using System;

namespace OpenBurnBar.App.Onboarding;

/// <summary>The three steps of the Prepare-Hermes wizard. Swift <c>HermesSetupStep</c>.</summary>
public enum HermesSetupStep
{
    Prepare = 0,
    Connect = 1,
    Chat = 2,
}

/// <summary>Step labels/headlines. Swift: the members on <c>HermesSetupStep</c>.</summary>
public static class HermesSetupStepExtensions
{
    public static readonly HermesSetupStep[] AllCases =
    {
        HermesSetupStep.Prepare,
        HermesSetupStep.Connect,
        HermesSetupStep.Chat,
    };

    public static double ProgressFraction(this HermesSetupStep step) =>
        (double)(int)step / (AllCases.Length - 1);

    public static string StepLabel(this HermesSetupStep step) => step switch
    {
        HermesSetupStep.Prepare => "1 · Prepare",
        HermesSetupStep.Connect => "2 · Connect",
        HermesSetupStep.Chat => "3 · Chat",
        _ => throw new ArgumentOutOfRangeException(nameof(step), step, null),
    };

    public static string Headline(this HermesSetupStep step) => step switch
    {
        HermesSetupStep.Prepare => "Prepare Hermes",
        HermesSetupStep.Connect => "Connect the gateway",
        HermesSetupStep.Chat => "Start chatting",
        _ => throw new ArgumentOutOfRangeException(nameof(step), step, null),
    };

    public static HermesSetupStep? Next(this HermesSetupStep step)
    {
        int raw = (int)step + 1;
        return raw <= (int)HermesSetupStep.Chat ? (HermesSetupStep)raw : null;
    }

    public static HermesSetupStep? Previous(this HermesSetupStep step)
    {
        int raw = (int)step - 1;
        return raw >= (int)HermesSetupStep.Prepare ? (HermesSetupStep)raw : null;
    }
}

/// <summary>The Connect step's status hero state. Swift <c>GatewayReachabilityState</c>.</summary>
public enum GatewayReachabilityState
{
    Unknown,
    CliMissing,
    ApiServerDisabled,
    DashboardOnly,
    GatewayRunning,
    Unreachable,
}

/// <summary>Tint for the status dot + hero hairline. Swift <c>GatewayReachabilityAccent</c>.</summary>
public enum GatewayReachabilityAccent
{
    Neutral,
    Warning,
    Blocked,
    Ready,
}

/// <summary>The copy + single primary action each reachability state carries. Swift: the
/// computed members on <c>GatewayReachabilityState</c>.</summary>
public static class GatewayReachabilityStateExtensions
{
    public static string Eyebrow(this GatewayReachabilityState state) => state switch
    {
        GatewayReachabilityState.Unknown => "GATEWAY",
        GatewayReachabilityState.CliMissing => "BLOCKED",
        GatewayReachabilityState.ApiServerDisabled => "CONFIG",
        GatewayReachabilityState.DashboardOnly => "PARTIAL",
        GatewayReachabilityState.GatewayRunning => "READY",
        GatewayReachabilityState.Unreachable => "OFFLINE",
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, null),
    };

    public static string Headline(this GatewayReachabilityState state) => state switch
    {
        GatewayReachabilityState.Unknown => "Waiting for Hermes",
        GatewayReachabilityState.CliMissing => "Hermes CLI not found",
        GatewayReachabilityState.ApiServerDisabled => "API server not ready",
        GatewayReachabilityState.DashboardOnly => "Dashboard up, gateway down",
        GatewayReachabilityState.GatewayRunning => "Gateway is reachable",
        GatewayReachabilityState.Unreachable => "Gateway not reachable",
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, null),
    };

    public static string Detail(this GatewayReachabilityState state) => state switch
    {
        GatewayReachabilityState.Unknown =>
            "OpenBurnBar hasn't probed the local gateway yet. Tap Check Health, or make it reachable in one step.",
        GatewayReachabilityState.CliMissing =>
            "Install the Hermes CLI, then return here. The wizard can open a terminal and copy the install command for you.",
        GatewayReachabilityState.ApiServerDisabled =>
            "Hermes needs both API_SERVER_ENABLED=true and API_SERVER_KEY in ~/.hermes/.env. OpenBurnBar can prepare both for you.",
        GatewayReachabilityState.DashboardOnly =>
            "The Hermes Dashboard is running, but the local gateway isn't reachable yet. Make it reachable in one step — OpenBurnBar will start the gateway for you.",
        GatewayReachabilityState.GatewayRunning =>
            "The local gateway is responding. You can continue to the test chat.",
        GatewayReachabilityState.Unreachable =>
            "Nothing is responding at the gateway address. Make it reachable in one step — OpenBurnBar will start the gateway and dashboard for you.",
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, null),
    };

    /// <summary>The single primary action label, or <c>null</c> when there is nothing for
    /// the user to do. Swift <c>primaryActionLabel</c>.</summary>
    public static string? PrimaryActionLabel(this GatewayReachabilityState state) => state switch
    {
        GatewayReachabilityState.Unknown
            or GatewayReachabilityState.DashboardOnly
            or GatewayReachabilityState.Unreachable => "Make Gateway Reachable",
        GatewayReachabilityState.CliMissing => null,
        GatewayReachabilityState.ApiServerDisabled => "Prepare API Server",
        GatewayReachabilityState.GatewayRunning => null,
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, null),
    };

    public static GatewayReachabilityAccent Accent(this GatewayReachabilityState state) => state switch
    {
        GatewayReachabilityState.Unknown => GatewayReachabilityAccent.Neutral,
        GatewayReachabilityState.CliMissing => GatewayReachabilityAccent.Blocked,
        GatewayReachabilityState.ApiServerDisabled => GatewayReachabilityAccent.Warning,
        GatewayReachabilityState.DashboardOnly => GatewayReachabilityAccent.Warning,
        GatewayReachabilityState.GatewayRunning => GatewayReachabilityAccent.Ready,
        GatewayReachabilityState.Unreachable => GatewayReachabilityAccent.Blocked,
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, null),
    };

    public static bool IsReady(this GatewayReachabilityState state) =>
        state == GatewayReachabilityState.GatewayRunning;
}

/// <summary>
/// The portable state machine behind the Prepare-Hermes wizard. Holds the Swift
/// controller's observable state and reproduces its derived <see cref="Reachability"/> +
/// step-gating exactly, with no I/O of its own. The Windows host supplies live probe /
/// config actions via the presentation layer; this type stays test-only-pure.
/// </summary>
public sealed class HermesSetupModel
{
    /// <summary>Current step. Swift <c>currentStep</c>.</summary>
    public HermesSetupStep CurrentStep { get; private set; } = HermesSetupStep.Prepare;

    /// <summary>Which edge the pending transition slides from. Swift <c>navigationDirection</c>.</summary>
    public OnboardingNavigationDirection LastNavigationDirection { get; private set; } =
        OnboardingNavigationDirection.Forward;

    // Prepare-step state (nullable = not checked yet). Swift: the same fields.
    public bool? HermesCliInstalled { get; set; }

    public string? HermesCliPath { get; set; }

    public bool? ApiServerEnabled { get; set; }

    public bool? HasApiServerKey { get; set; }

    public string BearerTokenInput { get; set; } = string.Empty;

    // Connect-step state.
    public bool IsGatewayRunning { get; set; }

    public bool IsDashboardRunning { get; set; }

    public int ProbeAttempts { get; set; }

    /// <summary>
    /// The single source of truth for the Connect step's hero. Swift <c>reachability</c>:
    /// CLI missing dominates, then API-server-not-ready, then gateway-running, then
    /// dashboard-only, then unknown (never probed) vs unreachable (probed, nothing).
    /// </summary>
    public GatewayReachabilityState Reachability
    {
        get
        {
            if (HermesCliInstalled == false)
            {
                return GatewayReachabilityState.CliMissing;
            }

            if (ApiServerEnabled != true || HasApiServerKey != true)
            {
                return GatewayReachabilityState.ApiServerDisabled;
            }

            if (IsGatewayRunning)
            {
                return GatewayReachabilityState.GatewayRunning;
            }

            if (IsDashboardRunning)
            {
                return GatewayReachabilityState.DashboardOnly;
            }

            return ProbeAttempts == 0
                ? GatewayReachabilityState.Unknown
                : GatewayReachabilityState.Unreachable;
        }
    }

    /// <summary>Prepare-step Continue gate. Swift <c>canContinueFromPrepare</c>:
    /// CLI present AND API server enabled AND key present.</summary>
    public bool CanContinueFromPrepare =>
        HermesCliInstalled == true && ApiServerEnabled == true && HasApiServerKey == true;

    /// <summary>Connect-step Continue gate. Swift <c>canContinueFromConnect</c>.</summary>
    public bool CanContinueFromConnect => IsGatewayRunning;

    /// <summary>Advance a step. Swift <c>navigateForward()</c>. No-op past Chat.</summary>
    public bool NavigateForward()
    {
        HermesSetupStep? next = CurrentStep.Next();
        if (next is null)
        {
            return false;
        }

        LastNavigationDirection = OnboardingNavigationDirection.Forward;
        CurrentStep = next.Value;
        return true;
    }

    /// <summary>Go back a step. Swift <c>navigateBack()</c>. No-op before Prepare.</summary>
    public bool NavigateBack()
    {
        HermesSetupStep? prev = CurrentStep.Previous();
        if (prev is null)
        {
            return false;
        }

        LastNavigationDirection = OnboardingNavigationDirection.Backward;
        CurrentStep = prev.Value;
        return true;
    }
}
