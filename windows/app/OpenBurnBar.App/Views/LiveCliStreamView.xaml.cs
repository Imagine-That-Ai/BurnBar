using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OpenBurnBar.App.Cli;
using OpenBurnBar.App.ViewModels;

namespace OpenBurnBar.App.Views;

/// <summary>
/// The live CLI-stream view: a Start/Stop toolbar over an auto-scrolling, color-coded log
/// bound to a <see cref="LiveCliStreamViewModel"/>. Host surfaces call <see cref="Attach"/>
/// with any <see cref="ICliStream"/>; the spike passes a stub, WINUI-017 passes the real
/// ConPTY source.
/// </summary>
public sealed partial class LiveCliStreamView : UserControl
{
    public LiveCliStreamView()
    {
        ViewModel = new LiveCliStreamViewModel(DispatcherQueue.GetForCurrentThread());
        InitializeComponent();
        ViewModel.LineAppended += (_, _) => ScrollToTail();
    }

    public LiveCliStreamViewModel ViewModel { get; }

    /// <summary>Compact mode shrinks the log type for the tray flyout.</summary>
    public bool Compact
    {
        get => (bool)GetValue(CompactProperty);
        set => SetValue(CompactProperty, value);
    }

    public static readonly DependencyProperty CompactProperty = DependencyProperty.Register(
        nameof(Compact), typeof(bool), typeof(LiveCliStreamView),
        new PropertyMetadata(false, OnCompactChanged));

    /// <summary>Bind a source; optionally begin streaming immediately.</summary>
    public void Attach(ICliStream stream, bool autoStart)
    {
        ViewModel.SetStream(stream);
        if (autoStart)
        {
            ViewModel.Start();
        }
    }

    /// <summary>Begin streaming only if not already running (used when the flyout opens).</summary>
    public void StartIfIdle()
    {
        if (ViewModel.CanStart)
        {
            ViewModel.Start();
        }
    }

    /// <summary>Stop streaming (used when a hosting window closes or hides).</summary>
    public void Detach() => ViewModel.Stop();

    private static void OnCompactChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var view = (LiveCliStreamView)d;
        if (view.LinesList is not null)
        {
            view.LinesList.FontSize = (bool)e.NewValue ? 11.5 : 12.5;
        }
    }

    private void ScrollToTail()
    {
        int count = ViewModel.Lines.Count;
        if (count > 0)
        {
            LinesList.ScrollIntoView(ViewModel.Lines[count - 1]);
        }
    }

    private void Start_Click(object sender, RoutedEventArgs e) => ViewModel.Start();

    private void Stop_Click(object sender, RoutedEventArgs e) => ViewModel.Stop();
}
