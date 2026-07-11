using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using OpenBurnBar.App.Diagnostics;
using OpenBurnBar.App.Particles;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Presentation.MissionControl;

namespace OpenBurnBar.App.MissionControl;

/// <summary>
/// The shell's Mission Control destination. Owns the <see cref="MissionConsoleViewModel"/> over
/// an <see cref="IMissionDispatchHost"/> (Firestore when configured; empty unless sample mode is
/// explicit), fans it out to the hero + composer + situation room, and hosts
/// the ambient particle backdrop on the landed Win2D <see cref="SwarmCanvasHost"/>.
/// </summary>
public sealed partial class MissionControlPage : Page
{
    private readonly MissionConsoleViewModel _viewModel;
    private readonly MissionBackdropFrameProvider _backdrop = new();
    private SwarmCanvasHost? _canvas;

    public MissionControlPage()
    {
        InitializeComponent();
        var root = WinAppCloudSyncHost.Root;
        _viewModel = new MissionConsoleViewModel(MissionDispatchHostFactory.Create(
            gateway: root?.Gateway,
            credentials: root?.Credentials,
            firebaseUid: root?.FirebaseUid));

        Hero.ViewModel = _viewModel;
        Composer.ViewModel = _viewModel;
        SituationRoom.ViewModel = _viewModel;

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        StartBackdrop();
        await _viewModel.RefreshAsync();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e) => StopBackdrop();

    /// <summary>Wire the landed Win2D swarm host as the ambient backdrop, driving it from the
    /// pure <see cref="MissionBackdropFrameProvider"/>.</summary>
    private void StartBackdrop()
    {
        if (_canvas is not null)
        {
            return;
        }
        if (!NativeCapability.IsWin2DEnabled(out _))
        {
            return;
        }

        try
        {
            _canvas = new SwarmCanvasHost
            {
                FrameProvider = (size, elapsed) =>
                    _backdrop.Build(size.Width, size.Height, elapsed.TotalSeconds),
            };
            BackdropHost.Child = _canvas.Control;
        }
        catch (Exception ex)
        {
            AppDiagnostics.LogException("mission.win2d", ex);
            _canvas = null;
            BackdropHost.Child = null;
        }
    }

    private void StopBackdrop()
    {
        if (_canvas is null)
        {
            return;
        }

        BackdropHost.Child = null;
        _canvas.Dispose();
        _canvas = null;
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        // The nav parameter is the NavDestination; the console owns its own data source.
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        StopBackdrop();
    }
}
