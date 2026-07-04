using System;
using System.ComponentModel;
using System.Collections.Generic;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Theme;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace OpenBurnBar.App.Onboarding;

/// <summary>
/// First-run onboarding wizard shell. Windows peer of <c>OnboardingWizardView.swift</c>:
/// a progress bar, a <see cref="Frame"/> that hosts the seven step Pages with slide
/// transitions, and a Back / Skip / Continue footer. All navigation/gating/labels come
/// from the portable, unit-tested <see cref="OnboardingWizardModel"/>; this Page only
/// reflects the model and forwards button clicks into it.
/// </summary>
public sealed partial class OnboardingPage : Page
{
    private OnboardingContext? _context;

    public OnboardingPage()
    {
        InitializeComponent();
        SizeChanged += (_, _) => UpdateProgress();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        if (_context is not null)
        {
            return;
        }

        var model = new OnboardingWizardModel();
        model.SetDetectedProviders(new[] { AgentProviderBrand.ClaudeCode, AgentProviderBrand.Codex });
        model.PreselectDetectedProviders();
        model.SeedChatBackends(ChatBackendMetadata.AllCases, ChatBackendId.Codex);

        Start(new OnboardingContext(model));
    }

    private OnboardingWizardModel? Model => _context?.Model;

    /// <summary>Bind the wizard to a host context and show the first step. The host seeds
    /// detected providers / existing backends on the model before calling this (mirroring
    /// the Swift <c>onAppear</c> pre-selection).</summary>
    public void Start(OnboardingContext context)
    {
        _context = context ?? throw new ArgumentNullException(nameof(context));
        context.Model.PropertyChanged += OnModelChanged;
        NavigateToCurrentStep(OnboardingNavigationDirection.Forward);
        SyncFooter();
        UpdateProgress();
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(OnboardingWizardModel.CurrentStep):
                NavigateToCurrentStep(Model?.LastNavigationDirection ?? OnboardingNavigationDirection.Forward);
                SyncFooter();
                UpdateProgress();
                break;
            case nameof(OnboardingWizardModel.CanContinue):
            case nameof(OnboardingWizardModel.ContinueLabel):
            case nameof(OnboardingWizardModel.ShowsFooter):
            case nameof(OnboardingWizardModel.ShowsBackButton):
            case nameof(OnboardingWizardModel.ShowsSkipButton):
                SyncFooter();
                break;
        }
    }

    private void NavigateToCurrentStep(OnboardingNavigationDirection direction)
    {
        if (_context is null || Model is null)
        {
            return;
        }

        Type pageType = StepPageType(Model.CurrentStep);
        var effect = direction == OnboardingNavigationDirection.Forward
            ? SlideNavigationTransitionEffect.FromRight
            : SlideNavigationTransitionEffect.FromLeft;
        StepFrame.Navigate(pageType, _context, new SlideNavigationTransitionInfo { Effect = effect });
    }

    private static Type StepPageType(OnboardingWizardStep step) => step switch
    {
        OnboardingWizardStep.Providers => typeof(ProvidersStepPage),
        OnboardingWizardStep.Connect => typeof(ConnectStepPage),
        OnboardingWizardStep.Scan => typeof(ScanStepPage),
        OnboardingWizardStep.Tour => typeof(TourStepPage),
        OnboardingWizardStep.SystemPermissions => typeof(SystemPermissionsStepPage),
        OnboardingWizardStep.ChatEngine => typeof(ChatEngineStepPage),
        OnboardingWizardStep.Complete => typeof(CompleteStepPage),
        _ => typeof(ProvidersStepPage),
    };

    private void SyncFooter()
    {
        if (Model is null)
        {
            return;
        }

        Footer.Visibility = Model.ShowsFooter ? Visibility.Visible : Visibility.Collapsed;
        BackButton.Visibility = Model.ShowsBackButton ? Visibility.Visible : Visibility.Collapsed;
        SkipButton.Visibility = Model.ShowsSkipButton ? Visibility.Visible : Visibility.Collapsed;
        ContinueButton.Content = Model.ContinueLabel;
        ContinueButton.IsEnabled = Model.CanContinue;
    }

    private void UpdateProgress()
    {
        if (Model is null)
        {
            return;
        }

        double full = ActualWidth > 0 ? ActualWidth : 520;
        ProgressFill.Width = Math.Max(0, Model.ProgressFraction * full);
    }

    private void OnBackClicked(object sender, RoutedEventArgs e) => Model?.NavigateBack();

    private void OnContinueClicked(object sender, RoutedEventArgs e) => Model?.NavigateForward();

    private void OnSkipClicked(object sender, RoutedEventArgs e)
    {
        Model?.Finalize();
        _context?.Dismiss?.Invoke();
    }
}
