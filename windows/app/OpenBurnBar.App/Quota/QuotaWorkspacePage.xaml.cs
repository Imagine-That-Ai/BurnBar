using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Components;
using OpenBurnBar.App.Theme;
using Windows.UI;

namespace OpenBurnBar.App.Quota;

/// <summary>
/// The Quota workspace page (Bucket C). Windows peer of
/// <c>AgentLens/Views/Dashboard/Quota/QuotaWorkspaceView.swift</c>: the constellation hero over a
/// grid of twin-ring dial cards. The page owns the <c>selectedProvider</c> focus (as the SwiftUI
/// <c>@State</c> does) and propagates it to both the hero and the dial grid via the parity-tested
/// <see cref="SubscriptionConstellation"/> filter passes.
/// </summary>
public sealed partial class QuotaWorkspacePage : Page
{
    private static readonly Color TextMuted = Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF);

    private IReadOnlyList<QuotaSampleAccount> _accounts = new List<QuotaSampleAccount>();
    private readonly Dictionary<string, QuotaSampleAccount> _byId = new();
    private AgentProviderBrand? _selected;
    private bool _built;

    public QuotaWorkspacePage()
    {
        InitializeComponent();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        if (_built)
        {
            return;
        }

        _built = true;
        _accounts = QuotaSampleData.Accounts();
        _byId.Clear();
        var entries = new List<SubscriptionEntry>(_accounts.Count);
        foreach (QuotaSampleAccount account in _accounts)
        {
            _byId[account.Entry.Id] = account;
            entries.Add(account.Entry);
        }

        Hero.Entries = entries;
        Hero.SelectedProvider = null;
        Hero.OrbTapped += OnOrbTapped;
        Hero.ClearRequested += OnClearRequested;

        RebuildDials();
    }

    private void OnOrbTapped(object? sender, AgentProviderBrand provider)
    {
        _selected = SubscriptionConstellation.ToggleSelection(_selected, provider);
        Hero.SelectedProvider = _selected;
        RebuildDials();
    }

    private void OnClearRequested(object? sender, System.EventArgs e)
    {
        _selected = null;
        Hero.SelectedProvider = null;
        RebuildDials();
    }

    private void RebuildDials()
    {
        DialHost.Children.Clear();

        var all = new List<SubscriptionEntry>(_accounts.Count);
        foreach (QuotaSampleAccount account in _accounts)
        {
            all.Add(account.Entry);
        }

        foreach (SubscriptionEntry entry in SubscriptionConstellation.DisplayedEntries(all, _selected))
        {
            if (entry.HasDisplayableBucket && _byId.TryGetValue(entry.Id, out QuotaSampleAccount? account))
            {
                DialHost.Children.Add(BuildCard(account));
            }
        }
    }

    private Border BuildCard(QuotaSampleAccount account)
    {
        var dial = new QuotaArcDial
        {
            Diameter = 120,
            Provider = account.Entry.Provider,
            OuterBucket = account.Outer,
            InnerBucket = account.Inner,
            VerticalAlignment = VerticalAlignment.Center,
        };

        var name = new TextBlock
        {
            Text = account.Entry.DisplayName,
            FontSize = 18,
            FontWeight = FontWeights.SemiBold,
            Foreground = (Brush)Application.Current.Resources["PensieveColorTextBrightBrush"],
        };

        var accountLabel = new TextBlock
        {
            Text = account.Entry.AccountLabel,
            FontSize = 12,
            Foreground = new SolidColorBrush(TextMuted),
        };

        var remaining = new TextBlock
        {
            Text = $"{account.Entry.RemainingPercentText} remaining",
            FontFamily = (FontFamily)Application.Current.Resources["PensieveFontMono"],
            FontSize = 12,
            Foreground = new SolidColorBrush(ProviderBrand.Primary(account.Entry.Provider)),
        };

        var text = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(name);
        text.Children.Add(accountLabel);
        text.Children.Add(remaining);

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
        row.Children.Add(dial);
        row.Children.Add(text);

        return new Border
        {
            Padding = new Thickness(16),
            CornerRadius = (CornerRadius)Application.Current.Resources["PensieveRadiusLgCorner"],
            Background = (Brush)Application.Current.Resources["PensieveColorGlassBgBrush"],
            BorderBrush = (Brush)Application.Current.Resources["PensieveColorGlassLineBrush"],
            BorderThickness = new Thickness(1),
            Child = row,
        };
    }
}
