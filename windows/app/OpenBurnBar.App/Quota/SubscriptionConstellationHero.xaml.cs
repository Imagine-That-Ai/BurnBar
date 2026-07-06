using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Components;
using OpenBurnBar.App.Theme;
using Windows.UI;

namespace OpenBurnBar.App.Quota;

/// <summary>
/// The Subscription Vault hero. Windows peer of
/// <c>AgentLens/Views/Dashboard/Quota/SubscriptionConstellationHero.swift</c>. Renders the eyebrow +
/// headline + meta strip + mercury hairline and a horizontal rail of <see cref="SubscriptionOrb"/>s,
/// one per provider (worst-pressured account). Copy + the chip set come from the parity-tested
/// <see cref="SubscriptionConstellation"/>; a tap re-raises <see cref="OrbTapped"/> and the inline
/// affordance raises <see cref="ClearRequested"/> so the workspace owns the focus state.
/// </summary>
public sealed partial class SubscriptionConstellationHero : UserControl
{
    private static readonly Color Muted = Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF);   // white 0.55
    private static readonly Color Ember = Color.FromArgb(0xFF, 0xFA, 0x50, 0x53);   // ember (dark)

    private IReadOnlyList<SubscriptionEntry> _entries = Array.Empty<SubscriptionEntry>();
    private AgentProviderBrand? _selectedProvider;

    public SubscriptionConstellationHero()
    {
        InitializeComponent();
        Loaded += (_, _) => Refresh();
    }

    /// <summary>Raised when an orb is tapped, carrying its provider. Swift: <c>onOrbTap</c>.</summary>
    public event EventHandler<AgentProviderBrand>? OrbTapped;

    /// <summary>Raised by the inline "Show all providers" affordance. Swift: <c>onClearSelection</c>.</summary>
    public event EventHandler? ClearRequested;

    /// <summary>The unfiltered entry set. Every provider stays visible while one is focused.</summary>
    public IReadOnlyList<SubscriptionEntry> Entries
    {
        get => _entries;
        set
        {
            _entries = value ?? Array.Empty<SubscriptionEntry>();
            Refresh();
        }
    }

    /// <summary>The focused provider, or null. Swift: <c>selectedProvider</c>.</summary>
    public AgentProviderBrand? SelectedProvider
    {
        get => _selectedProvider;
        set
        {
            _selectedProvider = value;
            Refresh();
        }
    }

    private bool IsFiltered => _selectedProvider is not null;

    /// <summary>Rebuild all hero content from the current entries + selection.</summary>
    public void Refresh()
    {
        if (OrbHost is null)
        {
            return;
        }

        IReadOnlyList<SubscriptionEntry> displayed =
            SubscriptionConstellation.DisplayedEntries(_entries, _selectedProvider);
        AggregateSummary summary = SubscriptionConstellation.Aggregate(displayed);

        EyebrowText.Text = SubscriptionConstellation.EyebrowText(summary, _selectedProvider);
        EyebrowText.Foreground = new SolidColorBrush(IsFiltered ? Ember : Muted);
        ClearButton.Visibility = IsFiltered ? Visibility.Visible : Visibility.Collapsed;

        HeadlineText.Text = SubscriptionConstellation.HeadlineText(summary, _selectedProvider);

        BuildMetaStrip(summary);
        BuildOrbs();
    }

    private void BuildMetaStrip(AggregateSummary summary)
    {
        MetaStrip.Children.Clear();

        var items = new List<string> { $"{summary.ActiveCount} ACTIVE" };
        if (summary.NextResetEntry is { } next)
        {
            items.Add($"NEXT RESET · {next.DisplayName.ToUpperInvariant()}");
        }

        if (summary.NearEdgeCount > 0)
        {
            items.Add($"{summary.NearEdgeCount} NEAR EDGE");
        }

        for (int i = 0; i < items.Count; i++)
        {
            if (i > 0)
            {
                MetaStrip.Children.Add(MetaLabel("·", dim: true));
            }

            MetaStrip.Children.Add(MetaLabel(items[i], dim: false));
        }
    }

    private TextBlock MetaLabel(string text, bool dim) => new()
    {
        Text = text,
        FontFamily = new FontFamily((string)Application.Current.Resources["PensieveFontMono"]),
        FontSize = 10,
        Foreground = new SolidColorBrush(dim ? Color.FromArgb(0x55, 0xFF, 0xFF, 0xFF) : Muted),
    };

    private void BuildOrbs()
    {
        OrbHost.Children.Clear();

        // Orbs derive from the UNFILTERED set so every provider stays pivotable while one is focused.
        IReadOnlyList<SubscriptionEntry> chips = SubscriptionConstellation.ProviderChipEntries(_entries);
        foreach (SubscriptionEntry entry in chips)
        {
            var orb = new SubscriptionOrb
            {
                Entry = entry,
                IsSelected = _selectedProvider == entry.Provider,
                IsDimmed = IsFiltered && _selectedProvider != entry.Provider,
            };
            orb.OrbTapped += (_, provider) => OrbTapped?.Invoke(this, provider);
            OrbHost.Children.Add(orb);
        }
    }

    private void OnClearClicked(object sender, RoutedEventArgs e) => ClearRequested?.Invoke(this, EventArgs.Empty);
}
