using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Onboarding;

/// <summary>Provider-cloud step. Windows peer of <c>OnboardingProviderCloudView.swift</c>:
/// a wrapping cloud of toggleable provider pills, detected-first, with "Select all
/// detected" and a live selected count.</summary>
public sealed partial class ProvidersStepPage : Page
{
    private OnboardingContext? _context;
    private readonly Dictionary<AgentProviderBrand, OnboardingProviderPill> _pills = new();

    public ProvidersStepPage()
    {
        InitializeComponent();
        Unloaded += OnUnloaded;
    }

    private OnboardingWizardModel? Model => _context?.Model;

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        _context = e.Parameter as OnboardingContext;
        if (_context is null || Model is null)
        {
            return;
        }

        BuildPills();
        Model.PropertyChanged += OnModelChanged;
        SyncCounts();
    }

    private void BuildPills()
    {
        if (_context is null || Model is null)
        {
            return;
        }

        ProviderCloud.Children.Clear();
        _pills.Clear();

        foreach (AgentProviderBrand provider in Model.SortedProviders(_context.DisplayName))
        {
            var pill = new OnboardingProviderPill();
            pill.Configure(
                provider,
                _context.DisplayName(provider),
                Model.IsProviderSelected(provider),
                Model.IsProviderDetected(provider));
            AgentProviderBrand captured = provider;
            pill.Toggled += (_, _) =>
            {
                Model.ToggleProvider(captured);
                pill.SetSelected(Model.IsProviderSelected(captured));
            };
            _pills[provider] = pill;
            ProviderCloud.Children.Add(pill);
        }
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(OnboardingWizardModel.SelectedProviders))
        {
            SyncCounts();
        }
    }

    private void SyncCounts()
    {
        if (Model is null)
        {
            return;
        }

        int detected = Model.DetectedProviders.Count;
        SelectAllDetectedButton.Visibility = detected > 0 ? Visibility.Visible : Visibility.Collapsed;
        SelectAllDetectedButton.Content = $"Select all detected ({detected})";
        SelectedCount.Text = $"{Model.SelectedProviders.Count} selected";
    }

    private void OnSelectAllDetected(object sender, RoutedEventArgs e)
    {
        if (Model is null)
        {
            return;
        }

        Model.SelectAllDetected();
        foreach (KeyValuePair<AgentProviderBrand, OnboardingProviderPill> entry in _pills)
        {
            entry.Value.SetSelected(Model.IsProviderSelected(entry.Key));
        }
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (Model is not null)
        {
            Model.PropertyChanged -= OnModelChanged;
        }
    }
}
