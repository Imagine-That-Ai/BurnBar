using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Components;
using OpenBurnBar.App.Presentation.Insights;
using Windows.UI;
using Windows.UI.Text;

namespace OpenBurnBar.App.Insights;

/// <summary>
/// One Insights canvas tile. Renders the chrome (glyph + title + kind chip) and dispatches the
/// body based on the widget's data — the Windows analog of <c>InsightWidgetRenderer</c>. Chart
/// kinds host a Win2D <see cref="InsightChartCanvas"/>; KPI, narrative, and recommendation use
/// native XAML; a null payload shows a skeleton.
/// </summary>
public sealed partial class InsightWidgetTile : UserControl
{
    private static readonly Color TextBright = Color.FromArgb(0xFF, 0xEC, 0xF1, 0xFA);
    private static readonly Color TextMuted = Color.FromArgb(0xAA, 0xC7, 0xCF, 0xDD);
    private static readonly Color SuccessColor = Color.FromArgb(0xFF, 0x4A, 0xD9, 0x91);
    private static readonly Color ErrorColor = Color.FromArgb(0xFF, 0xFA, 0x50, 0x53);

    private InsightChartCanvas? _chart;

    public InsightWidgetTile()
    {
        InitializeComponent();
        Unloaded += OnUnloaded;
    }

    /// <summary>Bind a widget + its canvas theme and build the body.</summary>
    public void SetWidget(InsightWidget widget, InsightTheme theme)
    {
        KindGlyph.Glyph = InsightWidgetKindInfo.Glyph(widget.Kind);
        TitleText.Text = widget.Title;
        KindChip.Text = InsightWidgetKindInfo.DisplayName(widget.Kind);

        DisposeChart();
        ContentHost.Child = BuildBody(widget, theme);
    }

    private UIElement BuildBody(InsightWidget widget, InsightTheme theme)
    {
        InsightWidgetData? data = widget.Data;
        return InsightRenderPlan.Resolve(data) switch
        {
            InsightRenderKind.Kpi when data is KpiData kpi => BuildKpi(kpi),
            InsightRenderKind.Narrative when data is NarrativeData n => BuildNarrative(n),
            InsightRenderKind.Recommendation when data is RecommendationData r => BuildRecommendation(r),
            InsightRenderKind.Skeleton => BuildMessage("Loading…"),
            InsightRenderKind.Empty when data is EmptyData e => BuildMessage(e.Reason),
            InsightRenderKind.Error when data is ErrorData err => BuildMessage(err.Message, ErrorColor),
            _ => BuildChart(data, theme),
        };
    }

    private UIElement BuildChart(InsightWidgetData? data, InsightTheme theme)
    {
        _chart = new InsightChartCanvas();
        _chart.SetContent(data, theme);
        return _chart.Control;
    }

    private static UIElement BuildKpi(KpiData kpi)
    {
        var stack = new StackPanel { Spacing = 4 };

        var headline = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        headline.Children.Add(new TextBlock
        {
            Text = InsightFormatting.Format(kpi.Value, kpi.ValueFormat),
            FontSize = 26,
            FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(TextBright),
        });
        if (kpi.Delta is double delta)
        {
            headline.Children.Add(DeltaPill(delta, kpi.DeltaIsPercent));
        }

        stack.Children.Add(headline);

        if (!string.IsNullOrEmpty(kpi.ContextLabel))
        {
            stack.Children.Add(new TextBlock
            {
                Text = kpi.ContextLabel,
                FontSize = 10,
                Foreground = new SolidColorBrush(TextMuted),
            });
        }

        if (kpi.SparklinePoints.Count > 0)
        {
            stack.Children.Add(new MiniSparkline
            {
                Data = kpi.SparklinePoints,
                Height = 36,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            });
        }

        return stack;
    }

    private static UIElement DeltaPill(double delta, bool isPercent)
    {
        bool positive = delta >= 0;
        Color color = positive ? SuccessColor : ErrorColor;
        var pill = new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Color.FromArgb(0x1F, color.R, color.G, color.B)),
            Padding = new Thickness(6, 1, 6, 1),
            VerticalAlignment = VerticalAlignment.Center,
        };
        pill.Child = new TextBlock
        {
            Text = InsightFormatting.FormatDelta(delta, isPercent),
            FontSize = 10,
            Foreground = new SolidColorBrush(color),
        };
        return pill;
    }

    private static UIElement BuildNarrative(NarrativeData n)
    {
        var stack = new StackPanel { Spacing = 4 };
        stack.Children.Add(new TextBlock
        {
            Text = n.Headline,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            Foreground = new SolidColorBrush(TextBright),
        });
        stack.Children.Add(new TextBlock
        {
            Text = n.Body,
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Foreground = new SolidColorBrush(TextMuted),
        });
        foreach (string bullet in n.BulletPoints)
        {
            stack.Children.Add(new TextBlock
            {
                Text = "• " + bullet,
                FontSize = 11,
                TextWrapping = TextWrapping.Wrap,
                Foreground = new SolidColorBrush(TextMuted),
            });
        }

        return stack;
    }

    private static UIElement BuildRecommendation(RecommendationData r)
    {
        var stack = new StackPanel { Spacing = 4 };
        stack.Children.Add(new TextBlock
        {
            Text = r.Headline,
            FontSize = 13,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            Foreground = new SolidColorBrush(TextBright),
        });
        stack.Children.Add(new TextBlock
        {
            Text = r.Rationale,
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Foreground = new SolidColorBrush(TextMuted),
        });
        stack.Children.Add(new TextBlock
        {
            Text = "→ " + r.Action,
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Foreground = new SolidColorBrush(SuccessColor),
        });
        return stack;
    }

    private static UIElement BuildMessage(string message) => BuildMessage(message, TextMuted);

    private static UIElement BuildMessage(string message, Color color)
        => new TextBlock
        {
            Text = message,
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(color),
        };

    private void OnUnloaded(object sender, RoutedEventArgs e) => DisposeChart();

    private void DisposeChart()
    {
        if (_chart is not null)
        {
            ContentHost.Child = null;
            _chart.Dispose();
            _chart = null;
        }
    }
}
