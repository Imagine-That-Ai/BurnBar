using System.Collections.Generic;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace OpenBurnBar.App.Components;

/// <summary>
/// A collapsed-by-default disclosure for a message's tool calls. Windows peer of
/// <c>OpenBurnBarCore/.../UnifiedToolCallAccordion.swift</c>. The collapsed row, +N badge, status
/// classification, and icons come from the parity-tested <see cref="ToolCallDisplay"/> /
/// <see cref="ToolCallAccordionModel"/>. Set <see cref="Calls"/> (oldest first) and
/// <see cref="AccentColor"/>.
/// </summary>
public sealed partial class UnifiedToolCallAccordion : UserControl
{
    // UnifiedDesignSystem success / error (dark) analogs + muted.
    private static readonly Color SuccessColor = Color.FromArgb(0xFF, 0x30, 0xD1, 0x58);
    private static readonly Color ErrorColor = Color.FromArgb(0xFF, 0xFF, 0x45, 0x3A);
    private static readonly Color MutedColor = Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF);
    private static readonly Color EmberDark = Color.FromArgb(0xFF, 0xFA, 0x50, 0x53);

    private bool _isExpanded;

    public UnifiedToolCallAccordion()
    {
        InitializeComponent();
        Loaded += (_, _) => Rebuild();
    }

    /// <summary>Tool calls in chronological order (oldest first). Swift: <c>calls</c>.</summary>
    public IReadOnlyList<ToolCallDisplay>? Calls
    {
        get => (IReadOnlyList<ToolCallDisplay>?)GetValue(CallsProperty);
        set => SetValue(CallsProperty, value);
    }

    public static readonly DependencyProperty CallsProperty = DependencyProperty.Register(
        nameof(Calls), typeof(IReadOnlyList<ToolCallDisplay>), typeof(UnifiedToolCallAccordion),
        new PropertyMetadata(null, OnVisualChanged));

    /// <summary>Surface accent tint. Swift: <c>accent.tint</c> (default ember).</summary>
    public Color AccentColor
    {
        get => (Color)GetValue(AccentColorProperty);
        set => SetValue(AccentColorProperty, value);
    }

    public static readonly DependencyProperty AccentColorProperty = DependencyProperty.Register(
        nameof(AccentColor), typeof(Color), typeof(UnifiedToolCallAccordion),
        new PropertyMetadata(EmberDark, OnVisualChanged));

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((UnifiedToolCallAccordion)d).Rebuild();

    private void Rebuild()
    {
        if (Root is null)
        {
            return;
        }

        IReadOnlyList<ToolCallDisplay> calls = Calls ?? System.Array.Empty<ToolCallDisplay>();
        ToolCallDisplay? mostRecent = ToolCallAccordionModel.MostRecent(calls);
        if (mostRecent is null)
        {
            Root.Visibility = Visibility.Collapsed;
            return;
        }

        Root.Visibility = Visibility.Visible;
        var accentBrush = new SolidColorBrush(AccentColor);
        Root.BorderBrush = new SolidColorBrush(WithAlpha(AccentColor, 0.5));

        HeaderIcon.Glyph = mostRecent.IconGlyph;
        HeaderIcon.Foreground = accentBrush;
        HeaderName.Text = mostRecent.Name;
        HeaderName.Foreground = accentBrush;

        string? detail = Trimmed(mostRecent.Detail);
        HeaderDetail.Text = detail ?? string.Empty;
        HeaderDetail.Visibility = detail is null ? Visibility.Collapsed : Visibility.Visible;

        int extra = ToolCallAccordionModel.AdditionalCount(calls);
        ExtraCount.Text = $"+{extra}";
        ExtraBadge.Visibility = extra > 0 && !_isExpanded ? Visibility.Visible : Visibility.Collapsed;

        StatusDot.Fill = new SolidColorBrush(DotColor(mostRecent.State, AccentColor));

        bool expandable = ToolCallAccordionModel.IsExpandable(calls);
        Chevron.Visibility = expandable ? Visibility.Visible : Visibility.Collapsed;
        HeaderButton.IsEnabled = expandable;
        ChevronRotation.Angle = _isExpanded ? 180 : 0;

        AutomationProperties.SetName(this, $"Tool call {mostRecent.Name}, {AccessibilityStatus(mostRecent.State)}");

        BuildExpandedBody(calls, mostRecent);
        ExpandedBody.Visibility = _isExpanded ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnHeaderClick(object sender, RoutedEventArgs e)
    {
        _isExpanded = !_isExpanded;
        Rebuild();
    }

    private void BuildExpandedBody(IReadOnlyList<ToolCallDisplay> calls, ToolCallDisplay mostRecent)
    {
        ExpandedBody.Children.Clear();
        if (!_isExpanded)
        {
            return;
        }

        ExpandedBody.Children.Add(DetailRows(mostRecent));
        foreach (ToolCallDisplay call in ToolCallAccordionModel.OlderCalls(calls))
        {
            ExpandedBody.Children.Add(Divider());
            ExpandedBody.Children.Add(DetailRows(call));
        }
    }

    private FrameworkElement DetailRows(ToolCallDisplay call)
    {
        var stack = new StackPanel { Spacing = 4 };

        var headerRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        headerRow.Children.Add(new FontIcon
        {
            FontFamily = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"),
            Glyph = call.IconGlyph,
            FontSize = 12,
            Foreground = new SolidColorBrush(AccentColor),
        });
        headerRow.Children.Add(new TextBlock
        {
            Text = call.Name,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = new SolidColorBrush(AccentColor),
        });
        headerRow.Children.Add(new Ellipse
        {
            Width = 7,
            Height = 7,
            VerticalAlignment = VerticalAlignment.Center,
            Fill = new SolidColorBrush(DotColor(call.State, AccentColor)),
        });
        stack.Children.Add(headerRow);

        string? detail = Trimmed(call.Detail);
        if (detail is not null)
        {
            stack.Children.Add(new TextBlock
            {
                Text = detail,
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                Foreground = new SolidColorBrush(MutedColor),
            });
        }

        string? arguments = Trimmed(call.Arguments);
        if (arguments is not null)
        {
            stack.Children.Add(MonospacedBlock("ARGUMENTS", arguments));
        }

        string? result = Trimmed(call.Result);
        if (result is not null)
        {
            stack.Children.Add(MonospacedBlock("RESULT", result));
        }

        return stack;
    }

    private static FrameworkElement MonospacedBlock(string label, string text)
    {
        var stack = new StackPanel { Spacing = 2 };
        stack.Children.Add(new TextBlock
        {
            Text = label,
            FontSize = 9,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = new SolidColorBrush(MutedColor),
        });
        stack.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(Color.FromArgb(0x8C, 0x05, 0x05, 0x08)),
            Padding = new Thickness(8),
            Child = new TextBlock
            {
                Text = text,
                FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                FontSize = 11,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                Foreground = new SolidColorBrush(Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF)),
            },
        });
        return stack;
    }

    private static Border Divider() => new()
    {
        Height = 1,
        Background = new SolidColorBrush(Color.FromArgb(0x14, 0xFF, 0xFF, 0xFF)),
    };

    private static Color DotColor(ToolCallState state, Color accent) => state switch
    {
        ToolCallState.Running => accent,
        ToolCallState.Done => SuccessColor,
        ToolCallState.Failed => ErrorColor,
        _ => MutedColor,
    };

    private static string AccessibilityStatus(ToolCallState state) => state switch
    {
        ToolCallState.Running => "running",
        ToolCallState.Done => "done",
        ToolCallState.Failed => "failed",
        _ => "completed",
    };

    private static string? Trimmed(string? value)
    {
        string? v = value?.Trim();
        return string.IsNullOrEmpty(v) ? null : v;
    }

    private static Color WithAlpha(Color c, double alpha) =>
        Color.FromArgb((byte)(alpha * 255), c.R, c.G, c.B);
}
