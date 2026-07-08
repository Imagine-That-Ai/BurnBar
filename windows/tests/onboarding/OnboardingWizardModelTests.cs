using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Onboarding;
using OpenBurnBar.App.Theme;
using Xunit;

namespace OpenBurnBar.App.Onboarding.Tests;

/// <summary>
/// Parity tests for the portable onboarding-wizard state machine. Every assertion
/// mirrors a rule the SwiftUI <c>OnboardingWizardView</c> expressed inline
/// (navigation, gating, tour sub-pagination, backend reassignment, completion).
/// </summary>
public sealed class OnboardingWizardModelTests
{
    // MARK: - Step order + progress

    [Fact]
    public void StepOrder_MatchesSwiftRawValueOrder()
    {
        Assert.Equal(
            new[]
            {
                OnboardingWizardStep.Providers,
                OnboardingWizardStep.Connect,
                OnboardingWizardStep.Scan,
                OnboardingWizardStep.Tour,
                OnboardingWizardStep.SystemPermissions,
                OnboardingWizardStep.ChatEngine,
                OnboardingWizardStep.Complete,
            },
            OnboardingWizardStepExtensions.AllCases);
    }

    [Fact]
    public void ProgressFraction_IsZeroAtProviders_AndOneAtComplete()
    {
        Assert.Equal(0.0, OnboardingWizardStep.Providers.ProgressFraction(), 6);
        Assert.Equal(1.0, OnboardingWizardStep.Complete.ProgressFraction(), 6);
        Assert.Equal(3.0 / 6.0, OnboardingWizardStep.Tour.ProgressFraction(), 6);
    }

    [Fact]
    public void InitialState_StartsAtProviders_ForwardDirection()
    {
        var model = new OnboardingWizardModel();
        Assert.Equal(OnboardingWizardStep.Providers, model.CurrentStep);
        Assert.Equal(OnboardingNavigationDirection.Forward, model.LastNavigationDirection);
        Assert.False(model.HasOnboarded);
        Assert.Equal(ChatBackendId.Codex, model.DefaultEngine);
    }

    // MARK: - The headline test: advance through every step to completion

    [Fact]
    public void AdvanceThroughAllSteps_ReachesComplete_AndFinalizeSetsCompletionState()
    {
        var model = new OnboardingWizardModel();
        model.SetDetectedProviders(new[] { AgentProviderBrand.ClaudeCode, AgentProviderBrand.Codex });
        model.PreselectDetectedProviders();
        model.SeedChatBackends(new[] { ChatBackendId.Codex, ChatBackendId.Hermes }, ChatBackendId.Hermes);

        // Providers -> Connect
        Assert.Equal("Continue", model.ContinueLabel);
        Assert.True(model.CanContinue); // two providers pre-selected
        Assert.True(model.NavigateForward());
        Assert.Equal(OnboardingWizardStep.Connect, model.CurrentStep);

        // Connect -> Scan
        Assert.Equal("Scan", model.ContinueLabel);
        Assert.True(model.NavigateForward());
        Assert.Equal(OnboardingWizardStep.Scan, model.CurrentStep);

        // Scan -> Tour (scan not refreshing)
        Assert.Equal("Continue", model.ContinueLabel);
        Assert.True(model.CanContinue);
        Assert.True(model.NavigateForward());
        Assert.Equal(OnboardingWizardStep.Tour, model.CurrentStep);

        // Tour sub-pages: Next x3 walks 0->3, then Continue advances the step.
        Assert.Equal(0, model.TourPage);
        Assert.Equal("Next", model.ContinueLabel);
        Assert.True(model.NavigateForward());
        Assert.Equal(1, model.TourPage);
        Assert.True(model.NavigateForward());
        Assert.Equal(2, model.TourPage);
        Assert.True(model.NavigateForward());
        Assert.Equal(3, model.TourPage);
        Assert.Equal("Continue", model.ContinueLabel);
        Assert.True(model.NavigateForward());
        Assert.Equal(OnboardingWizardStep.SystemPermissions, model.CurrentStep);

        // SystemPermissions -> ChatEngine
        Assert.Equal("Continue (set up later)", model.ContinueLabel);
        model.SystemPermissionsResolved = true;
        Assert.Equal("Continue", model.ContinueLabel);
        Assert.True(model.NavigateForward());
        Assert.Equal(OnboardingWizardStep.ChatEngine, model.CurrentStep);

        // ChatEngine -> Complete
        Assert.Equal("Finish", model.ContinueLabel);
        Assert.True(model.NavigateForward());
        Assert.Equal(OnboardingWizardStep.Complete, model.CurrentStep);
        Assert.Equal(1.0, model.ProgressFraction, 6);
        Assert.False(model.ShowsFooter); // Complete owns its own buttons

        // Advancing past Complete is a no-op.
        Assert.False(model.NavigateForward());
        Assert.Equal(OnboardingWizardStep.Complete, model.CurrentStep);

        // Finalize records completion state.
        OnboardingCompletionResult result = model.Finalize();
        Assert.True(model.HasOnboarded);
        Assert.Equal(
            new[] { ChatBackendId.Codex, ChatBackendId.Hermes },
            result.OrderedBackends);
        Assert.Equal(ChatBackendId.Hermes, result.StartEngine); // default engine still enabled
        Assert.Equal(2, result.SelectedProviders.Count);
        Assert.Contains(AgentProviderBrand.ClaudeCode, result.SelectedProviders);
        Assert.Contains(AgentProviderBrand.Codex, result.SelectedProviders);
    }

    // MARK: - Providers gate

    [Fact]
    public void ProvidersStep_CannotContinueWithNothingSelected()
    {
        var model = new OnboardingWizardModel();
        Assert.False(model.CanContinue);

        model.ToggleProvider(AgentProviderBrand.Cursor);
        Assert.True(model.CanContinue);

        model.ToggleProvider(AgentProviderBrand.Cursor); // toggle off again
        Assert.False(model.CanContinue);
    }

    [Fact]
    public void SelectAllDetected_SelectsEveryDetectedProvider()
    {
        var model = new OnboardingWizardModel();
        var detected = new[] { AgentProviderBrand.Codex, AgentProviderBrand.ClaudeCode, AgentProviderBrand.Cursor };
        model.SetDetectedProviders(detected);

        Assert.Empty(model.SelectedProviders);
        model.SelectAllDetected();
        Assert.Equal(3, model.SelectedProviders.Count);
        foreach (AgentProviderBrand provider in detected)
        {
            Assert.True(model.IsProviderSelected(provider));
            Assert.True(model.IsProviderDetected(provider));
        }
    }

    [Fact]
    public void SortedProviders_PutsDetectedFirst_ThenAlphabetical()
    {
        var model = new OnboardingWizardModel();
        model.SetDetectedProviders(new[] { AgentProviderBrand.Cursor });

        // Stable, deterministic display-name projection for the ordering assertion.
        string Name(AgentProviderBrand p) => p.ToString();
        IReadOnlyList<AgentProviderBrand> sorted = model.SortedProviders(Name);

        Assert.Equal(AgentProviderBrand.Cursor, sorted[0]); // the one detected provider leads
        IReadOnlyList<AgentProviderBrand> rest = sorted.Skip(1).ToList();
        Assert.Equal(rest.OrderBy(Name, System.StringComparer.Ordinal), rest); // remainder alphabetical
        Assert.Equal(System.Enum.GetValues<AgentProviderBrand>().Length, sorted.Count);
    }

    // MARK: - Scan gate

    [Fact]
    public void ScanStep_GateAndLabelFollowIsScanning()
    {
        var model = new OnboardingWizardModel();
        model.ToggleProvider(AgentProviderBrand.Codex);
        model.NavigateForward(); // Connect
        model.NavigateForward(); // Scan
        Assert.Equal(OnboardingWizardStep.Scan, model.CurrentStep);

        model.IsScanning = true;
        Assert.False(model.CanContinue);
        Assert.Equal("Scanning…", model.ContinueLabel);
        Assert.False(model.ShowsSkipButton); // Skip is hidden on Scan

        model.IsScanning = false;
        Assert.True(model.CanContinue);
        Assert.Equal("Continue", model.ContinueLabel);
    }

    // MARK: - Footer chrome

    [Fact]
    public void BackButton_HiddenOnProviders_ShownAfterward()
    {
        var model = new OnboardingWizardModel();
        Assert.False(model.ShowsBackButton);

        model.ToggleProvider(AgentProviderBrand.Codex);
        model.NavigateForward();
        Assert.True(model.ShowsBackButton);
    }

    // MARK: - Backward navigation

    [Fact]
    public void NavigateBack_ReversesTourSubPages_ThenSteps()
    {
        var model = new OnboardingWizardModel();
        model.ToggleProvider(AgentProviderBrand.Codex);
        model.NavigateForward(); // Connect
        model.NavigateForward(); // Scan
        model.NavigateForward(); // Tour (page 0)
        model.NavigateForward(); // Tour page 1
        model.NavigateForward(); // Tour page 2
        Assert.Equal(OnboardingWizardStep.Tour, model.CurrentStep);
        Assert.Equal(2, model.TourPage);

        Assert.True(model.NavigateBack()); // page 1
        Assert.Equal(1, model.TourPage);
        Assert.Equal(OnboardingWizardStep.Tour, model.CurrentStep);
        // Swift parity: a Tour sub-page step returns BEFORE touching navigationDirection,
        // so the outer slide direction is unchanged (still Forward from entering Tour) —
        // the sub-page carousel owns its own transition, not the outer Frame.
        Assert.Equal(OnboardingNavigationDirection.Forward, model.LastNavigationDirection);

        model.NavigateBack(); // page 0
        Assert.Equal(0, model.TourPage);
        model.NavigateBack(); // Scan (real step change -> direction flips to Backward)
        Assert.Equal(OnboardingWizardStep.Scan, model.CurrentStep);
        Assert.Equal(OnboardingNavigationDirection.Backward, model.LastNavigationDirection);
    }

    [Fact]
    public void NavigateBack_BeforeProviders_IsNoOp()
    {
        var model = new OnboardingWizardModel();
        Assert.False(model.NavigateBack());
        Assert.Equal(OnboardingWizardStep.Providers, model.CurrentStep);
    }

    // MARK: - Chat backend default reassignment

    [Fact]
    public void DisablingDefaultEngine_ReassignsToFirstRemaining()
    {
        var model = new OnboardingWizardModel();
        model.SetBackendEnabled(ChatBackendId.Hermes, true);
        model.SetBackendEnabled(ChatBackendId.Claude, true);
        model.DefaultEngine = ChatBackendId.Hermes;

        model.SetBackendEnabled(ChatBackendId.Hermes, false);

        // Ordered enabled is now [Claude]; default must fall to it.
        Assert.Equal(ChatBackendId.Claude, model.DefaultEngine);
        Assert.Equal(new[] { ChatBackendId.Claude }, model.OrderedEnabledBackends);
    }

    [Fact]
    public void DisablingLastEngine_FallsBackToCodex()
    {
        var model = new OnboardingWizardModel();
        model.SetBackendEnabled(ChatBackendId.Hermes, true);
        model.DefaultEngine = ChatBackendId.Hermes;

        model.SetBackendEnabled(ChatBackendId.Hermes, false);

        Assert.Empty(model.OrderedEnabledBackends);
        Assert.Equal(ChatBackendId.Codex, model.DefaultEngine);
    }

    // MARK: - Finalize edge cases

    [Fact]
    public void Finalize_WithNoBackends_LeavesStartEngineNull()
    {
        var model = new OnboardingWizardModel();
        model.ToggleProvider(AgentProviderBrand.Codex);

        OnboardingCompletionResult result = model.Finalize();
        Assert.Empty(result.OrderedBackends);
        Assert.Null(result.StartEngine);
        Assert.True(model.HasOnboarded);
    }

    [Fact]
    public void Finalize_WhenDefaultDisabled_StartsWithFirstEnabled()
    {
        var model = new OnboardingWizardModel();
        // Enable claude + hermes but leave the default as the disabled Codex.
        model.SetBackendEnabled(ChatBackendId.Claude, true);
        model.SetBackendEnabled(ChatBackendId.Hermes, true);
        // DefaultEngine was reassigned to Claude when Codex was never enabled — force the
        // Swift "default not in ordered" path explicitly.
        model.DefaultEngine = ChatBackendId.Codex;

        OnboardingCompletionResult result = model.Finalize();
        Assert.Equal(new[] { ChatBackendId.Claude, ChatBackendId.Hermes }, result.OrderedBackends);
        Assert.Equal(ChatBackendId.Claude, result.StartEngine); // first enabled, since default absent
    }

    // MARK: - Change notification

    [Fact]
    public void CurrentStep_RaisesPropertyChanged()
    {
        var model = new OnboardingWizardModel();
        model.ToggleProvider(AgentProviderBrand.Codex);
        var changed = new List<string?>();
        model.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        model.NavigateForward();

        Assert.Contains(nameof(OnboardingWizardModel.CurrentStep), changed);
        Assert.Contains(nameof(OnboardingWizardModel.ProgressFraction), changed);
        Assert.Contains(nameof(OnboardingWizardModel.ContinueLabel), changed);
    }
}
