using System;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Onboarding;

/// <summary>
/// The navigation parameter passed to every onboarding step Page. Bundles the portable
/// <see cref="OnboardingWizardModel"/> with the host callbacks a step needs (open the
/// dashboard, dismiss to the tray, launch the Hermes setup dialog) plus the readouts the
/// Complete/Scan steps surface. Keeps step Pages free of any direct host coupling.
/// </summary>
public sealed class OnboardingContext
{
    public OnboardingContext(OnboardingWizardModel model)
    {
        Model = model ?? throw new ArgumentNullException(nameof(model));
    }

    /// <summary>The wizard state machine every step reads/mutates.</summary>
    public OnboardingWizardModel Model { get; }

    /// <summary>Provider display-name projection (defaults to the parity table).</summary>
    public Func<AgentProviderBrand, string> DisplayName { get; init; } = ProviderDisplay.DisplayName;

    /// <summary>Invoked by the Complete step's "Open Dashboard".</summary>
    public Action? OpenDashboard { get; init; }

    /// <summary>Invoked by the Complete step's "Stay in menu bar" / the footer Skip.</summary>
    public Action? Dismiss { get; init; }

    /// <summary>Invoked by the Chat-engine step's Hermes "Setup wizard" button.</summary>
    public Action? ShowHermesSetup { get; init; }

    /// <summary>Total discovered usage sessions, for the Complete summary. Swift:
    /// <c>dataStore.totalUsageSessionCount</c>.</summary>
    public int SessionCount { get; init; }

    /// <summary>Providers with sessions, for the Complete summary. Swift:
    /// <c>dataStore.providerSummaries(for: .allTime).count</c>.</summary>
    public int ProviderCount { get; init; }
}
