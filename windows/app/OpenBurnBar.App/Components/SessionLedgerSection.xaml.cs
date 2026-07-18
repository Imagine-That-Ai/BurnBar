using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Theme;
using Windows.UI;

namespace OpenBurnBar.App.Components;

/// <summary>
/// The searchable, time-bucketed session list. Windows peer of
/// <c>AgentLens/Views/Components/SessionLedgerSection.swift</c>. Search + bucketing + grouping run
/// through the parity-tested <see cref="SessionLedgerSupport"/> /
/// <see cref="SessionLedgerBucketExtensions"/>; rows are built here. Assign
/// <see cref="Usages"/>; handle <see cref="SessionSelected"/>.
/// </summary>
public sealed partial class SessionLedgerSection : UserControl
{
    private static readonly Color SuccessColor = Color.FromArgb(0xFF, 0x30, 0xD1, 0x58);
    private SessionLedgerBucket _bucket = SessionLedgerBucket.Day;
    private string _search = string.Empty;

    public SessionLedgerSection()
    {
        InitializeComponent();
        BuildGroupByButtons();
        Loaded += (_, _) => Rebuild();
    }

    /// <summary>Raised when a row is tapped. Swift: <c>onOpenUsage</c> / <c>selectedSession</c>.</summary>
    public event EventHandler<SessionLedgerRow>? SessionSelected;

    /// <summary>The sessions to render. Swift: <c>usages</c>.</summary>
    public IReadOnlyList<SessionLedgerRow>? Usages
    {
        get => (IReadOnlyList<SessionLedgerRow>?)GetValue(UsagesProperty);
        set => SetValue(UsagesProperty, value);
    }

    public static readonly DependencyProperty UsagesProperty = DependencyProperty.Register(
        nameof(Usages), typeof(IReadOnlyList<SessionLedgerRow>), typeof(SessionLedgerSection),
        new PropertyMetadata(null, OnVisualChanged));

    /// <summary>Accent provider (row rail tint). Swift: <c>theme</c>.</summary>
    public AgentProviderBrand Provider
    {
        get => (AgentProviderBrand)GetValue(ProviderProperty);
        set => SetValue(ProviderProperty, value);
    }

    public static readonly DependencyProperty ProviderProperty = DependencyProperty.Register(
        nameof(Provider), typeof(AgentProviderBrand), typeof(SessionLedgerSection),
        new PropertyMetadata(AgentProviderBrand.Factory, OnVisualChanged));

    /// <summary>Show the per-row provider badge (model drill-down). Swift: <c>showsAgentBadge</c>.</summary>
    public bool ShowsAgentBadge
    {
        get => (bool)GetValue(ShowsAgentBadgeProperty);
        set => SetValue(ShowsAgentBadgeProperty, value);
    }

    public static readonly DependencyProperty ShowsAgentBadgeProperty = DependencyProperty.Register(
        nameof(ShowsAgentBadge), typeof(bool), typeof(SessionLedgerSection),
        new PropertyMetadata(false, OnVisualChanged));

    /// <summary>"currency" shows cost; anything else shows token volume. Swift: <c>displayMode</c>.</summary>
    public string DisplayMode
    {
        get => (string)GetValue(DisplayModeProperty);
        set => SetValue(DisplayModeProperty, value);
    }

    public static readonly DependencyProperty DisplayModeProperty = DependencyProperty.Register(
        nameof(DisplayMode), typeof(string), typeof(SessionLedgerSection),
        new PropertyMetadata("currency", OnVisualChanged));

    /// <summary>Caption under the heading. Swift: <c>footerCaption</c>.</summary>
    public string FooterCaption
    {
        get => (string)GetValue(FooterCaptionProperty);
        set => SetValue(FooterCaptionProperty, value);
    }

    public static readonly DependencyProperty FooterCaptionProperty = DependencyProperty.Register(
        nameof(FooterCaption), typeof(string), typeof(SessionLedgerSection),
        new PropertyMetadata(string.Empty, OnVisualChanged));

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((SessionLedgerSection)d).Rebuild();

    private void BuildGroupByButtons()
    {
        foreach (SessionLedgerBucket bucket in Enum.GetValues<SessionLedgerBucket>())
        {
            var button = new Button
            {
                Content = bucket.ShortLabel(),
                Tag = bucket,
                MinWidth = 52,
                Padding = new Thickness(11, 7, 11, 7),
                Background = new SolidColorBrush(Colors.Transparent),
                BorderThickness = new Thickness(0),
                FontSize = 11,
            };
            button.Click += OnBucketClick;
            GroupByHost.Children.Add(button);
        }
    }

    private void OnBucketClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: SessionLedgerBucket bucket })
        {
            _bucket = bucket;
            Rebuild();
        }
    }

    private void OnSearchChanged(object sender, TextChangedEventArgs e)
    {
        _search = SearchBox.Text ?? string.Empty;
        Rebuild();
    }

    private void Rebuild()
    {
        if (GroupsHost is null)
        {
            return;
        }

        Caption.Text = FooterCaption;
        Color accent = ProviderBrand.Primary(Provider);
        HighlightSelectedBucket(accent);

        IReadOnlyList<SessionLedgerRow> usages = Usages ?? Array.Empty<SessionLedgerRow>();
        bool hasUsages = usages.Count > 0;
        EmptyLedger.Visibility = hasUsages ? Visibility.Collapsed : Visibility.Visible;
        Controls.Visibility = hasUsages ? Visibility.Visible : Visibility.Collapsed;

        GroupsHost.Children.Clear();
        if (!hasUsages)
        {
            NoMatches.Visibility = Visibility.Collapsed;
            return;
        }

        List<SessionLedgerRow> filtered = usages
            .Where(u => SessionLedgerSupport.MatchesSearch(u, _search))
            .ToList();

        if (filtered.Count == 0)
        {
            NoMatches.Visibility = Visibility.Visible;
            return;
        }

        NoMatches.Visibility = Visibility.Collapsed;
        foreach (SessionLedgerGroup group in SessionLedgerSupport.GroupedSessions(filtered, _bucket))
        {
            GroupsHost.Children.Add(BuildGroup(group, accent));
        }
    }

    private void HighlightSelectedBucket(Color accent)
    {
        foreach (UIElement child in GroupByHost.Children)
        {
            if (child is Button { Tag: SessionLedgerBucket bucket } button)
            {
                bool selected = bucket == _bucket;
                button.Foreground = new SolidColorBrush(selected
                    ? accent
                    : Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF));
                button.Background = new SolidColorBrush(selected ? WithAlpha(accent, 0.14) : Colors.Transparent);
            }
        }
    }

    private FrameworkElement BuildGroup(SessionLedgerGroup group, Color accent)
    {
        var stack = new StackPanel { Spacing = 8 };

        var headerRow = new Grid();
        headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var title = new TextBlock
        {
            Text = group.Title,
            FontSize = 12,
            Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)),
        };
        int count = group.Sessions.Count;
        var countText = new TextBlock
        {
            Text = $"{count} session{(count == 1 ? string.Empty : "s")}",
            FontSize = 10,
            FontFamily = BrandFonts.Mono,
            Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)),
        };
        Grid.SetColumn(countText, 1);
        headerRow.Children.Add(title);
        headerRow.Children.Add(countText);
        stack.Children.Add(headerRow);

        var rows = new StackPanel { Spacing = 4 };
        foreach (SessionLedgerRow usage in group.Sessions)
        {
            rows.Children.Add(BuildRow(usage, accent));
        }

        stack.Children.Add(rows);
        return stack;
    }

    private FrameworkElement BuildRow(SessionLedgerRow usage, Color accent)
    {
        var border = new Border
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(12, 8, 12, 8),
            Background = new SolidColorBrush(Color.FromArgb(0x8F, 0x12, 0x12, 0x1A)),
            BorderThickness = new Thickness(usage.CacheEfficient ? 1.5 : 0),
            BorderBrush = new SolidColorBrush(usage.CacheEfficient ? SuccessColor : Colors.Transparent),
        };

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnSpacing = 12;

        var rail = new Border
        {
            Width = 3,
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(accent),
        };
        grid.Children.Add(rail);

        var left = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        var timeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        timeRow.Children.Add(new TextBlock
        {
            Text = usage.StartTime.ToString("h:mm tt", CultureInfo.InvariantCulture),
            FontSize = 11,
            FontFamily = BrandFonts.Mono,
            Foreground = new SolidColorBrush(accent),
        });
        if (ShowsAgentBadge)
        {
            timeRow.Children.Add(new Border
            {
                Padding = new Thickness(6, 2, 6, 2),
                CornerRadius = new CornerRadius(999),
                Background = new SolidColorBrush(WithAlpha(accent, 0.12)),
                Child = new TextBlock
                {
                    Text = usage.ProviderDisplayName,
                    FontSize = 10,
                    Foreground = new SolidColorBrush(accent),
                },
            });
        }

        left.Children.Add(timeRow);
        left.Children.Add(new TextBlock
        {
            Text = usage.ProjectName,
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            Foreground = new SolidColorBrush(Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF)),
        });
        Grid.SetColumn(left, 1);
        grid.Children.Add(left);

        var right = new StackPanel { Spacing = 3, HorizontalAlignment = HorizontalAlignment.Right };
        right.Children.Add(new TextBlock
        {
            Text = DisplayMode == "currency" ? FormatCost(usage.Cost) : FormatTokens(usage.TotalTokens),
            FontSize = 13,
            FontFamily = BrandFonts.Mono,
            HorizontalAlignment = HorizontalAlignment.Right,
            Foreground = new SolidColorBrush(Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF)),
        });
        right.Children.Add(new TextBlock
        {
            Text = usage.Model,
            FontSize = 10,
            HorizontalAlignment = HorizontalAlignment.Right,
            Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)),
        });
        if (usage.CacheEfficient)
        {
            right.Children.Add(new TextBlock
            {
                Text = "Cache efficient",
                FontSize = 10,
                HorizontalAlignment = HorizontalAlignment.Right,
                Foreground = new SolidColorBrush(SuccessColor),
            });
        }

        Grid.SetColumn(right, 2);
        grid.Children.Add(right);

        border.Child = grid;
        AutomationProperties.SetName(border, $"{usage.ProjectName}, {usage.Model}");
        border.Tapped += (_, _) => SessionSelected?.Invoke(this, usage);
        return border;
    }

    private static string FormatCost(double cost) =>
        cost.ToString("C2", CultureInfo.GetCultureInfo("en-US"));

    private static string FormatTokens(long tokens)
    {
        if (tokens >= 1_000_000_000) return (tokens / 1_000_000_000.0).ToString("0.0", CultureInfo.InvariantCulture) + "B";
        if (tokens >= 1_000_000) return (tokens / 1_000_000.0).ToString("0.0", CultureInfo.InvariantCulture) + "M";
        if (tokens >= 1_000) return (tokens / 1_000.0).ToString("0.0", CultureInfo.InvariantCulture) + "K";
        return tokens.ToString(CultureInfo.InvariantCulture);
    }

    private static Color WithAlpha(Color c, double alpha) =>
        Color.FromArgb((byte)(alpha * 255), c.R, c.G, c.B);
}
