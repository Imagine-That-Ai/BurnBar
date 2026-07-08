using System;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Xaml;
using OpenBurnBar.App.Pet.Behavior;
using OpenBurnBar.App.Pet.Chat;
using OpenBurnBar.App.Pet.Definition;
using OpenBurnBar.App.Pet.Gltf;
using OpenBurnBar.App.Presentation.Chat;
using OpenBurnBar.Pal.Overlay;
using WinRT.Interop;

namespace OpenBurnBar.App.Pet;

/// <summary>
/// The transparent, click-through PetCompanion overlay window. Styles its own HWND
/// with the shared <see cref="ExistingWindowOverlay"/> flag set, hosts the three.js
/// pet (via <see cref="WebView2PetGltfHost"/> + <see cref="PetGltfSceneController"/>),
/// and drives it from the portable <see cref="PetCompanionController"/>. Windows-gated.
/// </summary>
public sealed partial class PetOverlayWindow : Window
{
    private readonly PetCompanionController _controller;
    private readonly PetChatBubbleViewModel _bubbleViewModel;
    private readonly WebView2PetGltfHost _host;
    private readonly PetGltfSceneController _scene;
    private readonly string? _glbUrl;
    private IntPtr _hwnd;

    /// <param name="graph">The pet's behavior graph (from its petdef.json).</param>
    /// <param name="chat">The LANDED Chat state machine driving the bubble.</param>
    /// <param name="definition">The parsed petdef (clip inventory + glb).</param>
    /// <param name="glbUrl">The virtual-host URL of the .glb to load (e.g. the
    /// claudecode-crab model).</param>
    public PetOverlayWindow(
        PetBehaviorGraph graph,
        ChatSessionStateMachine chat,
        PetDefinition? definition = null,
        string? glbUrl = null)
    {
        InitializeComponent();

        _host = new WebView2PetGltfHost(PetWebView);
        _scene = new PetGltfSceneController(_host);
        _controller = new PetCompanionController(graph, chat, definition, _scene);
        _bubbleViewModel = new PetChatBubbleViewModel(chat, _controller);
        _glbUrl = glbUrl;

        Bubble.Bind(_bubbleViewModel);
        _controller.ActivityChanged += OnActivityChanged;

        ApplyOverlayStyle();
        Activated += OnActivatedOnce;
    }

    /// The portable controller (exposed for the tray / hotkey to summon the pet).
    public PetCompanionController Controller => _controller;

    private void OnActivatedOnce(object sender, WindowActivatedEventArgs args)
    {
        Activated -= OnActivatedOnce;
        _ = StartAsync();
    }

    private async Task StartAsync(CancellationToken cancellationToken = default)
    {
        await _scene.StartAsync(cancellationToken).ConfigureAwait(true);
        if (_glbUrl is not null)
        {
            await _scene.LoadModelAsync(_glbUrl, draco: true, cancellationToken).ConfigureAwait(true);
            var clip = _controller.CurrentClip ?? "idle";
            await _scene.PlayClipAsync(clip, PetClipResolver.ShouldLoop(_controller.CurrentLogicalNode), cancellationToken: cancellationToken)
                .ConfigureAwait(true);
        }
    }

    private void ApplyOverlayStyle()
    {
        _hwnd = WindowNative.GetWindowHandle(this);
        // Layered + tool-window + topmost + no-activate, click-through ON by default
        // (the pet ignores the mouse until it is grabbed / the bubble opens).
        ExistingWindowOverlay.ApplyOverlayStyle(_hwnd, clickThrough: true);
    }

    private void OnActivityChanged(PetActivityState activity)
    {
        // When the pet is engaged (Active / Summon) the bubble is interactive, so the
        // overlay must stop passing clicks through; when it drifts back to Idle it
        // becomes click-through again.
        var interactive = activity != PetActivityState.Idle;
        if (_hwnd != IntPtr.Zero)
        {
            ExistingWindowOverlay.SetClickThrough(_hwnd, clickThrough: !interactive);
        }
        Bubble.Visibility = interactive ? Visibility.Visible : Visibility.Collapsed;
    }
}
