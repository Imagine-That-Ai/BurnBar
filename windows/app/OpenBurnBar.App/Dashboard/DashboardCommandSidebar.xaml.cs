using System;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Theme;
using Windows.System;
using Windows.UI;

namespace OpenBurnBar.App.Dashboard;

/// <summary>
/// Command rail for the Dashboard — Windows peer of
/// <c>AgentLens/Views/Dashboard/DashboardSidebarView.swift</c>.
/// </summary>
public sealed partial class DashboardCommandSidebar : UserControl
{
    private DashboardCommandSnapshot _snapshot = DashboardCommandSnapshot.Empty;
    private DashboardCommandViewMode _mode = DashboardCommandViewMode.Agents;
    private string _selectedKey = "overview";

    public DashboardCommandSidebar()
    {
        InitializeComponent();
        ApplyModeChrome();
        ActualThemeChanged += OnActualThemeChanged;
    }

    /// <summary>Raised when the user picks Overview / a provider / a model row.</summary>
    public event EventHandler<DashboardCommandSelection>? SelectionChanged;

    /// <summary>Raised when Agents/Models mode flips (resets selection to Overview on macOS).</summary>
    public event EventHandler<DashboardCommandViewMode>? ViewModeChanged;

    public DashboardCommandViewMode ViewMode => _mode;

    public string SelectedKey => _selectedKey;

    public void ApplySnapshot(DashboardCommandSnapshot snapshot)
    {
        _snapshot = snapshot ?? DashboardCommandSnapshot.Empty;
        WindowRange.Text = _snapshot.TimeRangeDisplayName;
        WindowProviders.Text = $"{_snapshot.ActiveProviderCount} active provider{(_snapshot.ActiveProviderCount == 1 ? string.Empty : "s")}";
        RebuildRows();
    }

    public void SetViewMode(DashboardCommandViewMode mode, bool raise = false)
    {
        if (_mode == mode && !raise)
        {
            ApplyModeChrome();
            RebuildRows();
            return;
        }

        _mode = mode;
        _selectedKey = "overview";
        ApplyModeChrome();
        RebuildRows();
        if (raise)
        {
            ViewModeChanged?.Invoke(this, _mode);
            RaiseSelection(DashboardCommandSelection.Overview());
        }
    }

    public void SelectOverview()
    {
        _selectedKey = "overview";
        RebuildRows();
        RaiseSelection(DashboardCommandSelection.Overview());
    }

    private void OnAgentsModeClick(object sender, RoutedEventArgs e) =>
        SetViewMode(DashboardCommandViewMode.Agents, raise: true);

    private void OnModelsModeClick(object sender, RoutedEventArgs e) =>
        SetViewMode(DashboardCommandViewMode.Models, raise: true);

    private void OnActualThemeChanged(FrameworkElement sender, object args)
    {
        ApplyModeChrome();
        RebuildRows();
    }

    private async void OnCursorClick(object sender, RoutedEventArgs e)
    {
        // macOS openBurnBarCursorExtension — cursor: then vscode: fallback.
        Uri[] candidates =
        {
            new("cursor:extension/openburnbar.openburnbar"),
            new("https://marketplace.visualstudio.com/items?itemName=openburnbar.openburnbar"),
        };
        foreach (Uri uri in candidates)
        {
            try
            {
                if (await Launcher.LaunchUriAsync(uri))
                {
                    return;
                }
            }
            catch
            {
                // try next
            }
        }
    }

    private void ApplyModeChrome()
    {
        bool agents = _mode == DashboardCommandViewMode.Agents;
        ModeTitle.Text = agents ? "Agent providers" : "LLM Models";
        ModeCaption.Text = agents
            ? "Scan, compare spend, and drill into model behavior from one workspace."
            : "Track spend and token volume across every model your agents use.";

        Brush selectedBg = ResourceBrush("AuroraGlassTintElevatedBrush")
            ?? new SolidColorBrush(Color.FromArgb(0x44, 0xFF, 0xFF, 0xFF));
        Brush mutedFg = ResourceBrush("AuroraTextSecondaryBrush")
            ?? new SolidColorBrush(Color.FromArgb(0xCC, 0xC8, 0xD0, 0xE0));
        Brush brightFg = ResourceBrush("AuroraTextBrush")
            ?? new SolidColorBrush(Colors.White);

        AgentsModeButton.Background = agents ? selectedBg : new SolidColorBrush(Colors.Transparent);
        ModelsModeButton.Background = agents ? new SolidColorBrush(Colors.Transparent) : selectedBg;

        if (AgentsModeButton.Content is TextBlock agentsLabel)
        {
            agentsLabel.Foreground = agents ? brightFg : mutedFg;
        }

        if (ModelsModeButton.Content is TextBlock modelsLabel)
        {
            modelsLabel.Foreground = agents ? mutedFg : brightFg;
        }
    }

    private void RebuildRows()
    {
        RowsHost.Children.Clear();

        RowsHost.Children.Add(BuildRow(
            key: "overview",
            title: "All Providers",
            subtitle: $"{_snapshot.SessionCount} session{(_snapshot.SessionCount == 1 ? string.Empty : "s")}",
            metric: _snapshot.OverviewMetricLabel,
            accent: Color.FromArgb(0xFF, 0xC9, 0xA2, 0x4A),
            glyph: "\uE80A"));

        if (_mode == DashboardCommandViewMode.Agents)
        {
            foreach (DashboardProviderSidebarRow row in _snapshot.Providers)
            {
                Color brand = BrandColorForProvider(row.Id);
                RowsHost.Children.Add(BuildRow(
                    key: "provider:" + row.Id,
                    title: row.DisplayName,
                    subtitle: $"{row.SessionCount} session{(row.SessionCount == 1 ? string.Empty : "s")}",
                    metric: row.MetricLabel,
                    accent: brand,
                    glyph: "\uE950"));
            }

            EmptyHint.Visibility = _snapshot.Providers.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            EmptyHint.Text = "No providers in this window";
        }
        else
        {
            foreach (DashboardModelSidebarRow row in _snapshot.Models)
            {
                Color brand = ProviderBrand.ColorForModelBrush(row.Id);
                RowsHost.Children.Add(BuildRow(
                    key: "model:" + row.Id,
                    title: row.DisplayName,
                    subtitle: $"{row.SessionCount} session{(row.SessionCount == 1 ? string.Empty : "s")}",
                    metric: row.MetricLabel,
                    accent: brand,
                    glyph: "\uE8F1"));
            }

            EmptyHint.Visibility = _snapshot.Models.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
            EmptyHint.Text = "No models in this window";
        }
    }

    private static Color BrandColorForProvider(string providerId) =>
        ResolveProvider(providerId) is { } brand
            ? ProviderBrand.Primary(brand)
            : Color.FromArgb(0xFF, 0xC9, 0xA2, 0x4A);

    private static AgentProviderBrand? ResolveProvider(string providerId) =>
        providerId.Trim().ToLowerInvariant() switch
        {
            "openai" => AgentProviderBrand.OpenAI,
            "anthropic" or "claude" or "claudecode" => AgentProviderBrand.ClaudeCode,
            "cursor" => AgentProviderBrand.Cursor,
            "grok" or "xai" => AgentProviderBrand.XAI,
            "gemini" or "google" => AgentProviderBrand.GeminiCLI,
            "copilot" or "github" => AgentProviderBrand.Copilot,
            "codex" => AgentProviderBrand.Codex,
            "ollama" => AgentProviderBrand.Ollama,
            "hermes" => AgentProviderBrand.Hermes,
            "factory" => AgentProviderBrand.Factory,
            _ => null,
        };

    private Button BuildRow(string key, string title, string subtitle, string metric, Color accent, string glyph)
    {
        bool selected = string.Equals(_selectedKey, key, StringComparison.Ordinal);
        Color accentColor = accent;
        var accentBrush = new SolidColorBrush(accentColor);

        var button = new Button
        {
            Tag = key,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(10, 8, 10, 8),
            CornerRadius = new CornerRadius(10),
            BorderThickness = new Thickness(1),
            BorderBrush = selected
                ? new SolidColorBrush(Color.FromArgb(0x4D, accentColor.R, accentColor.G, accentColor.B))
                : ResourceBrush("AuroraGlassStrokeBrush") ?? new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)),
            Background = selected
                ? new SolidColorBrush(Color.FromArgb(0x14, accentColor.R, accentColor.G, accentColor.B))
                : ResourceBrush("AuroraGlassTintBaseBrush"),
        };

        var grid = new Grid { ColumnSpacing = 10 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var iconPlate = new Border
        {
            Width = 34,
            Height = 34,
            CornerRadius = new CornerRadius(17),
            Background = selected
                ? new SolidColorBrush(Color.FromArgb(0x2E, accentColor.R, accentColor.G, accentColor.B))
                : ResourceBrush("AuroraGlassTintElevatedBrush")
                    ?? new SolidColorBrush(Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF)),
            Child = new FontIcon
            {
                Glyph = glyph,
                FontSize = 14,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Foreground = selected
                    ? accentBrush
                    : ResourceBrush("AuroraTextSecondaryBrush")
                        ?? new SolidColorBrush(Color.FromArgb(0xCC, 0xC8, 0xD0, 0xE0)),
            },
        };
        Grid.SetColumn(iconPlate, 0);

        var labels = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        labels.Children.Add(new TextBlock
        {
            Text = title,
            FontSize = 13,
            FontWeight = selected ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = selected
                ? ResourceBrush("AuroraTextBrush")
                : ResourceBrush("AuroraTextSecondaryBrush"),
        });
        labels.Children.Add(new TextBlock
        {
            Text = subtitle,
            FontSize = 11,
            Foreground = ResourceBrush("AuroraTextMutedBrush"),
        });
        Grid.SetColumn(labels, 1);

        var trailing = new StackPanel
        {
            Spacing = 2,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        trailing.Children.Add(new TextBlock
        {
            Text = metric,
            FontSize = 12,
            FontFamily = BrandFonts.Mono,
            HorizontalAlignment = HorizontalAlignment.Right,
            Foreground = selected ? accentBrush : ResourceBrush("AuroraTextMutedBrush"),
        });
        trailing.Children.Add(new FontIcon
        {
            Glyph = "\uE76C",
            FontSize = 9,
            HorizontalAlignment = HorizontalAlignment.Right,
            Foreground = selected
                ? new SolidColorBrush(Color.FromArgb(0xCC, accentColor.R, accentColor.G, accentColor.B))
                : ResourceBrush("AuroraTextMutedBrush"),
        });
        Grid.SetColumn(trailing, 2);

        grid.Children.Add(iconPlate);
        grid.Children.Add(labels);
        grid.Children.Add(trailing);
        button.Content = grid;
        button.Click += (_, _) =>
        {
            _selectedKey = key;
            RebuildRows();
            RaiseSelection(DashboardCommandSelection.Parse(key, title));
        };

        return button;
    }

    private void RaiseSelection(DashboardCommandSelection selection) =>
        SelectionChanged?.Invoke(this, selection);

    private Brush? ResourceBrush(string key)
    {
        if (Application.Current?.Resources.TryGetValue(key, out object res) == true && res is Brush brush)
        {
            return brush;
        }
        if (Resources.TryGetValue(key, out object localRes) && localRes is Brush localBrush)
        {
            return localBrush;
        }
        return null;
    }
}

/// <summary>Selection payload from the Command sidebar.</summary>
public sealed class DashboardCommandSelection
{
    private DashboardCommandSelection(string kind, string? id, string title)
    {
        Kind = kind;
        Id = id;
        Title = title;
    }

    public string Kind { get; }
    public string? Id { get; }
    public string Title { get; }

    public bool IsOverview => Kind == "overview";

    public static DashboardCommandSelection Overview() => new("overview", null, "All Providers");

    public static DashboardCommandSelection Parse(string key, string title)
    {
        if (key.StartsWith("provider:", StringComparison.Ordinal))
        {
            return new DashboardCommandSelection("provider", key["provider:".Length..], title);
        }

        if (key.StartsWith("model:", StringComparison.Ordinal))
        {
            return new DashboardCommandSelection("model", key["model:".Length..], title);
        }

        return Overview();
    }
}
