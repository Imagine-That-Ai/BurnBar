using System.Collections.Generic;
using System.Threading.Tasks;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using OpenBurnBar.App.Presentation.Chat;
using OpenBurnBar.App.Theme;
using OpenBurnBar.Pretext;

namespace OpenBurnBar.App.Chat;

/// <summary>
/// Windows peer of the macOS <c>HermesRichBubble</c>. Lays a parsed run stream
/// out using the LANDED Pretext WebView2 host: each run becomes a
/// <see cref="PretextRichInlineItem"/>, the engine computes the wrapped lines,
/// and each <see cref="PretextRichFragment"/> is mapped back to its source run
/// for font/chip rendering — the same fragment→run recovery the SwiftUI bubble
/// does. Until the engine resolves (or when none is attached) a RichTextBlock
/// fallback renders the same prose inline.
/// </summary>
public sealed partial class StreamingBubble : UserControl
{
    private const double BaseSize = 14;
    private const double LineHeight = BaseSize * 1.36;
    private const double FallbackWidthFloor = 4;

    private PretextEngine? _engine;
    private int _measureVersion;

    public StreamingBubble()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        ActualThemeChanged += OnActualThemeChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_engine is null && ChatPretextEngineHost.Current is { } shared)
        {
            Engine = shared;
        }
        ChatPretextEngineHost.CurrentChanged += OnSharedEngineChanged;
    }

    private void OnUnloaded(object sender, RoutedEventArgs e) =>
        ChatPretextEngineHost.CurrentChanged -= OnSharedEngineChanged;

    private void OnSharedEngineChanged(PretextEngine? engine)
    {
        if (engine is not null)
        {
            Engine = engine;
        }
    }

    private void OnActualThemeChanged(FrameworkElement sender, object args) => Refresh();

    /// The parsed run stream to render (from <see cref="HermesAtomParser.Parse"/>).
    public IReadOnlyList<HermesRichRun>? Runs
    {
        get => (IReadOnlyList<HermesRichRun>?)GetValue(RunsProperty);
        set => SetValue(RunsProperty, value);
    }

    public static readonly DependencyProperty RunsProperty = DependencyProperty.Register(
        nameof(Runs), typeof(IReadOnlyList<HermesRichRun>), typeof(StreamingBubble),
        new PropertyMetadata(null, OnRunsChanged));

    /// The Pretext engine used for measurement. Set by the host once its
    /// offscreen WebView2 is ready; the bubble re-measures when it arrives.
    public PretextEngine? Engine
    {
        get => _engine;
        set
        {
            _engine = value;
            Refresh();
        }
    }

    /// Raised when a rendered atom chip is invoked (the WinUI analog of the
    /// macOS <c>HermesAtomRouter.open</c>).
    public event System.Action<HermesAtom>? AtomInvoked;

    private static void OnRunsChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((StreamingBubble)d).Refresh();

    private void OnSizeChanged(object sender, SizeChangedEventArgs e) => Refresh();

    private void Refresh()
    {
        var runs = Runs;
        if (runs is null || runs.Count == 0)
        {
            LinesPanel.Children.Clear();
            Fallback.Blocks.Clear();
            return;
        }

        BuildFallback(runs);

        var width = ActualWidth;
        if (_engine is null || width <= FallbackWidthFloor)
        {
            // No engine (or collapsed width): show the inline fallback only.
            LinesPanel.Children.Clear();
            Fallback.Visibility = Visibility.Visible;
            return;
        }

        _ = MeasureAsync(runs, width, ++_measureVersion);
    }

    private async Task MeasureAsync(IReadOnlyList<HermesRichRun> runs, double width, int version)
    {
        var items = new List<PretextRichInlineItem>(runs.Count);
        foreach (var run in runs)
        {
            items.Add(new PretextRichInlineItem
            {
                Text = run.Text,
                Font = CanvasFont(run),
                BreakNever = run.IsAtomic,
                ExtraWidth = ExtraWidth(run),
            });
        }

        PretextRichHandle handle;
        IReadOnlyList<PretextRichLine> lines;
        try
        {
            handle = await _engine!.PrepareRichInlineAsync(items).ConfigureAwait(true);
            lines = await _engine!.LayoutRichInlineAsync(handle, width).ConfigureAwait(true);
            await _engine!.ReleaseAsync(handle).ConfigureAwait(true);
        }
        catch (PretextException)
        {
            // Engine unavailable / bridge error: keep the inline fallback.
            return;
        }

        if (version != _measureVersion)
        {
            return; // a newer measurement superseded this one.
        }

        BuildLines(runs, lines);
        Fallback.Visibility = Visibility.Collapsed;
    }

    private void BuildLines(IReadOnlyList<HermesRichRun> runs, IReadOnlyList<PretextRichLine> lines)
    {
        LinesPanel.Children.Clear();
        foreach (var line in lines)
        {
            var row = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                MinHeight = LineHeight,
            };
            foreach (var fragment in line.Fragments)
            {
                var element = RenderFragment(runs, fragment);
                if (fragment.GapBefore > 0)
                {
                    element.Margin = new Thickness(fragment.GapBefore, 0, 0, 0);
                }
                row.Children.Add(element);
            }
            LinesPanel.Children.Add(row);
        }
    }

    private FrameworkElement RenderFragment(IReadOnlyList<HermesRichRun> runs, PretextRichFragment fragment)
    {
        if (fragment.ItemIndex < 0 || fragment.ItemIndex >= runs.Count)
        {
            return new TextBlock { Text = fragment.Text, FontSize = BaseSize, Foreground = TextBrush() };
        }

        var run = runs[fragment.ItemIndex];
        switch (run.Kind)
        {
            case HermesRichRunKind.Atom when run.Atom is { } atom:
                var chip = new HermesAtomChip { Atom = atom, Label = fragment.Text };
                chip.Invoked += a => AtomInvoked?.Invoke(a);
                return chip;

            case HermesRichRunKind.Mention:
                return Pill(fragment.Text, "AuroraAccentBrush", mono: false);

            case HermesRichRunKind.Code:
                return Pill(fragment.Text, "AuroraTextBrush", mono: true);

            default:
                var text = new TextBlock
                {
                    Text = fragment.Text,
                    FontSize = BaseSize,
                    Foreground = TextBrush(),
                    FontWeight = run.Style.HasFlag(HermesInlineStyle.Bold) ? FontWeights.SemiBold : FontWeights.Normal,
                    FontStyle = run.Style.HasFlag(HermesInlineStyle.Italic)
                        ? Windows.UI.Text.FontStyle.Italic
                        : Windows.UI.Text.FontStyle.Normal,
                    TextDecorations = run.Style.HasFlag(HermesInlineStyle.Strikethrough)
                        ? Windows.UI.Text.TextDecorations.Strikethrough
                        : Windows.UI.Text.TextDecorations.None,
                };
                return text;
        }
    }

    private Border Pill(string text, string brushKey, bool mono)
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = BaseSize - 1,
            Foreground = Brush(brushKey),
        };
        if (mono)
        {
            block.FontFamily = BrandMonoFont();
        }
        else
        {
            block.FontWeight = FontWeights.SemiBold;
        }

        return new Border
        {
            Child = block,
            Padding = new Thickness(5, 1, 5, 1),
            CornerRadius = new CornerRadius(5),
            Background = Brush("AuroraGlassTintElevatedBrush"),
        };
    }

    private void BuildFallback(IReadOnlyList<HermesRichRun> runs)
    {
        Fallback.Blocks.Clear();
        var paragraph = new Paragraph();
        foreach (var run in runs)
        {
            var inline = new Run { Text = run.Text };
            if (run.Kind == HermesRichRunKind.Body)
            {
                if (run.Style.HasFlag(HermesInlineStyle.Bold))
                {
                    inline.FontWeight = FontWeights.SemiBold;
                }
                if (run.Style.HasFlag(HermesInlineStyle.Italic))
                {
                    inline.FontStyle = Windows.UI.Text.FontStyle.Italic;
                }
            }
            else if (run.Kind == HermesRichRunKind.Code)
            {
                inline.FontFamily = BrandMonoFont();
            }
            else
            {
                inline.FontWeight = FontWeights.SemiBold;
            }
            paragraph.Inlines.Add(inline);
        }
        Fallback.Blocks.Add(paragraph);
    }

    private static string CanvasFont(HermesRichRun run) => run.Kind switch
    {
        HermesRichRunKind.Code => "500 13px 'JetBrains Mono', 'Cascadia Mono', monospace",
        HermesRichRunKind.Mention => "600 13px 'Geist', 'Segoe UI', sans-serif",
        HermesRichRunKind.Atom => "600 13px 'Geist', 'Segoe UI', sans-serif",
        _ => (run.Style.HasFlag(HermesInlineStyle.Bold) ? "600 " : "400 ") + "14px 'Geist', 'Segoe UI', sans-serif",
    };

    private static double ExtraWidth(HermesRichRun run) => run.Kind switch
    {
        HermesRichRunKind.Atom => 30,
        HermesRichRunKind.Mention => 16,
        HermesRichRunKind.Code => 12,
        _ => 0,
    };

    private Brush TextBrush() => Brush("AuroraTextBrush");

    // AuroraMonoFont lives at the Typography.xaml dictionary root (theme-independent),
    // so an Application-level lookup resolves it (see Theme/BrandFonts.cs).
    private static FontFamily BrandMonoFont() => BrandFonts.Mono;

    // The hidden XAML probes use real ThemeResource bindings. Reading their typed
    // Background values keeps code-built fragments aligned with the current theme.
    private Brush Brush(string key) => key switch
    {
        "AuroraTextBrush" => AuroraTextBrushProbe.Background,
        "AuroraAccentBrush" => AuroraAccentBrushProbe.Background,
        "AuroraGlassTintElevatedBrush" => AuroraGlassTintElevatedBrushProbe.Background,
        _ => null,
    } ?? new SolidColorBrush(Microsoft.UI.Colors.White);
}
