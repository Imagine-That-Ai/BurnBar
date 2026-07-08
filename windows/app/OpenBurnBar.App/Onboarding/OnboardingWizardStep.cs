// PORTED (portable, unit-tested) from AgentLens/Views/Onboarding/OnboardingWizardView.swift
//   enum OnboardingWizardStep: Int, CaseIterable { ... }
//
// This is the dependency-free (System-only, NO WinUI) step vocabulary for the
// Windows onboarding wizard. It compiles and runs on the macOS authoring host so
// the wizard's step ordering + progress math is asserted by a real `dotnet test`
// (windows/tests/onboarding). The WinUI presentation (OnboardingPage + step Pages)
// consumes it but is Windows-only and type-checked separately (XamlCompiler gate).

namespace OpenBurnBar.App.Onboarding;

/// <summary>
/// The seven ordered steps of the first-run wizard. Mirrors the Swift
/// <c>OnboardingWizardStep</c> raw-value order exactly so the progress fraction and
/// the forward/back sequence are byte-for-byte with macOS.
/// </summary>
public enum OnboardingWizardStep
{
    /// <summary>Provider cloud — choose the coding agents to track.</summary>
    Providers = 0,

    /// <summary>Connection status — which selected agents have local logs.</summary>
    Connect = 1,

    /// <summary>Scanning logs — parse history + parser-health readout.</summary>
    Scan = 2,

    /// <summary>Product tour — the surfaces you use every day.</summary>
    Tour = 3,

    /// <summary>System permissions — OS-level grants (Windows-appropriate items).</summary>
    SystemPermissions = 4,

    /// <summary>Chat engines — enable backends + pick a default.</summary>
    ChatEngine = 5,

    /// <summary>Complete — summary + open dashboard / stay in tray.</summary>
    Complete = 6,
}

/// <summary>Step ordering + progress helpers. Swift: the <c>CaseIterable</c> +
/// <c>progressFraction</c> members on <c>OnboardingWizardStep</c>.</summary>
public static class OnboardingWizardStepExtensions
{
    /// <summary>All steps in wizard order (Swift <c>allCases</c>).</summary>
    public static readonly OnboardingWizardStep[] AllCases =
    {
        OnboardingWizardStep.Providers,
        OnboardingWizardStep.Connect,
        OnboardingWizardStep.Scan,
        OnboardingWizardStep.Tour,
        OnboardingWizardStep.SystemPermissions,
        OnboardingWizardStep.ChatEngine,
        OnboardingWizardStep.Complete,
    };

    /// <summary>
    /// Progress bar fill fraction 0..1. Swift:
    /// <c>Double(rawValue) / Double(allCases.count - 1)</c>. Providers = 0, Complete = 1.
    /// </summary>
    public static double ProgressFraction(this OnboardingWizardStep step) =>
        (double)(int)step / (AllCases.Length - 1);

    /// <summary>The next step, or <c>null</c> at <see cref="OnboardingWizardStep.Complete"/>.
    /// Swift: <c>OnboardingWizardStep(rawValue: rawValue + 1)</c>.</summary>
    public static OnboardingWizardStep? Next(this OnboardingWizardStep step)
    {
        int raw = (int)step + 1;
        return raw <= (int)OnboardingWizardStep.Complete ? (OnboardingWizardStep)raw : null;
    }

    /// <summary>The previous step, or <c>null</c> at <see cref="OnboardingWizardStep.Providers"/>.
    /// Swift: <c>OnboardingWizardStep(rawValue: rawValue - 1)</c>.</summary>
    public static OnboardingWizardStep? Previous(this OnboardingWizardStep step)
    {
        int raw = (int)step - 1;
        return raw >= (int)OnboardingWizardStep.Providers ? (OnboardingWizardStep)raw : null;
    }
}

/// <summary>The direction the next step transition should slide. Mirrors the Swift
/// <c>navigationDirection: Edge</c> (.trailing on forward, .leading on back) that drives
/// the asymmetric move transition — here it selects the Frame slide effect.</summary>
public enum OnboardingNavigationDirection
{
    /// <summary>Advancing — new step slides in from the trailing edge (Swift <c>.trailing</c>).</summary>
    Forward,

    /// <summary>Going back — new step slides in from the leading edge (Swift <c>.leading</c>).</summary>
    Backward,
}
