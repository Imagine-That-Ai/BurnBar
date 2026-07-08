using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace OpenBurnBar.App.Components;

/// <summary>An update-banner action the user can invoke. Presentational; the shell wires these
/// to the Windows update service (out of Bucket A).</summary>
public enum UpdateBannerAction
{
    Install,
    Later,
    ViewChanges,
    CheckAgain,
}

/// <summary>
/// The "update available" card. Windows peer of
/// <c>AgentLens/Views/Components/UpdateBannerCard.swift</c>. All copy comes from the parity-tested
/// <see cref="UpdateBannerState"/>; the plate routes through the Liquid-Glass chokepoint. Set
/// <see cref="State"/> and (optionally) <see cref="Compact"/>; handle <see cref="ActionInvoked"/>.
/// </summary>
public sealed partial class UpdateBannerCard : UserControl
{
    private static readonly Color EmberDark = Color.FromArgb(0xFF, 0xFA, 0x50, 0x53);
    private static readonly Color ErrorColor = Color.FromArgb(0xFF, 0xFF, 0x45, 0x3A);

    public UpdateBannerCard()
    {
        InitializeComponent();
        Loaded += (_, _) => Rebuild();
    }

    /// <summary>Raised when the user taps an action button.</summary>
    public event EventHandler<UpdateBannerAction>? ActionInvoked;

    /// <summary>The presentational state. Swift: <c>DirectDownloadUpdateChecker.phase</c>.</summary>
    public UpdateBannerState? State
    {
        get => (UpdateBannerState?)GetValue(StateProperty);
        set => SetValue(StateProperty, value);
    }

    public static readonly DependencyProperty StateProperty = DependencyProperty.Register(
        nameof(State), typeof(UpdateBannerState), typeof(UpdateBannerCard),
        new PropertyMetadata(null, OnVisualChanged));

    /// <summary>Tighter layout for the flyout. Swift: <c>UpdateBannerCard.compact</c>.</summary>
    public bool Compact
    {
        get => (bool)GetValue(CompactProperty);
        set => SetValue(CompactProperty, value);
    }

    public static readonly DependencyProperty CompactProperty = DependencyProperty.Register(
        nameof(Compact), typeof(bool), typeof(UpdateBannerCard),
        new PropertyMetadata(false, OnVisualChanged));

    private static void OnVisualChanged(DependencyObject d, DependencyPropertyChangedEventArgs e) =>
        ((UpdateBannerCard)d).Rebuild();

    private void Rebuild()
    {
        if (Root is null)
        {
            return;
        }

        if (State is not { } state || !state.IsActionable)
        {
            Root.Visibility = Visibility.Collapsed;
            return;
        }

        Root.Visibility = Visibility.Visible;
        bool compact = Compact;
        bool failed = state.Phase == UpdatePhaseKind.Failed;
        Color accent = failed ? ErrorColor : EmberDark;

        IconDisc.Background = new SolidColorBrush(accent);
        HeaderIcon.Glyph = state.IconGlyph;
        TitleText.Text = state.Title;

        string? subtitle = state.Subtitle;
        // Compact shows the subtitle inline (tiny) under the title; full shows the wrapped block.
        SubtitleInline.Text = subtitle ?? string.Empty;
        SubtitleInline.Visibility = compact && subtitle is { Length: > 0 } ? Visibility.Visible : Visibility.Collapsed;
        SubtitleBlock.Text = subtitle ?? string.Empty;
        SubtitleBlock.Visibility = !compact && subtitle is { Length: > 0 } ? Visibility.Visible : Visibility.Collapsed;

        if (state.PillText is { Length: > 0 } pill)
        {
            VersionText.Text = pill;
            VersionPill.Visibility = Visibility.Visible;
        }
        else
        {
            VersionPill.Visibility = Visibility.Collapsed;
        }

        AutomationProperties.SetName(this, state.AccessibilityLabel);
        BuildBody(state, compact);
    }

    private void BuildBody(UpdateBannerState state, bool compact)
    {
        BodyHost.Children.Clear();

        switch (state.Phase)
        {
            case UpdatePhaseKind.Available:
                BuildActions(state, compact);
                break;

            case UpdatePhaseKind.Downloading:
                BodyHost.Children.Add(new ProgressBar
                {
                    Minimum = 0,
                    Maximum = 1,
                    Value = Math.Clamp(state.DownloadProgress, 0, 1),
                    Foreground = new SolidColorBrush(EmberDark),
                });
                BodyHost.Children.Add(Muted($"Downloading… {(int)Math.Round(state.DownloadProgress * 100)}%"));
                break;

            case UpdatePhaseKind.Verifying:
            case UpdatePhaseKind.Installing:
            case UpdatePhaseKind.Relaunching:
                BodyHost.Children.Add(Indeterminate(state.IndeterminateLabel ?? string.Empty));
                break;

            case UpdatePhaseKind.Failed:
                if (!compact && state.FailureMessage is { Length: > 0 } message)
                {
                    BodyHost.Children.Add(Wrapped(message));
                }

                var failRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                failRow.Children.Add(ActionButton("Check Again", UpdateBannerAction.CheckAgain, prominent: true));
                BodyHost.Children.Add(failRow);
                break;
        }
    }

    private void BuildActions(UpdateBannerState state, bool compact)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        switch (state.Offer)
        {
            case UpdateOfferKind.DirectDownload:
                row.Children.Add(ActionButton("Install Update", UpdateBannerAction.Install, prominent: true));
                if (!compact)
                {
                    row.Children.Add(ActionButton("Later", UpdateBannerAction.Later, prominent: false));
                }

                break;

            case UpdateOfferKind.Winget:
                row.Children.Add(ActionButton("Update via winget", UpdateBannerAction.Install, prominent: true));
                if (!compact)
                {
                    row.Children.Add(ActionButton("Later", UpdateBannerAction.Later, prominent: false));
                }

                break;

            case UpdateOfferKind.Source:
                row.Children.Add(ActionButton("Pull · Rebuild", UpdateBannerAction.Install, prominent: true));
                if (!compact)
                {
                    row.Children.Add(ActionButton("View Changes", UpdateBannerAction.ViewChanges, prominent: false));
                }

                break;
        }

        BodyHost.Children.Add(row);
    }

    private Button ActionButton(string text, UpdateBannerAction action, bool prominent)
    {
        var button = new Button { Content = text };
        if (prominent)
        {
            button.Style = Application.Current.Resources["AccentButtonStyle"] as Style;
        }

        button.Click += (_, _) => ActionInvoked?.Invoke(this, action);
        return button;
    }

    private static ProgressRing SmallRing() => new()
    {
        IsActive = true,
        Width = 16,
        Height = 16,
    };

    private StackPanel Indeterminate(string label)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(SmallRing());
        row.Children.Add(Muted(label));
        return row;
    }

    private static TextBlock Muted(string text) => new()
    {
        Text = text,
        FontSize = 12,
        Foreground = new SolidColorBrush(Color.FromArgb(0x8C, 0xFF, 0xFF, 0xFF)),
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static TextBlock Wrapped(string text) => new()
    {
        Text = text,
        FontSize = 12,
        TextWrapping = TextWrapping.Wrap,
        Foreground = new SolidColorBrush(Color.FromArgb(0xD9, 0xFF, 0xFF, 0xFF)),
    };
}
