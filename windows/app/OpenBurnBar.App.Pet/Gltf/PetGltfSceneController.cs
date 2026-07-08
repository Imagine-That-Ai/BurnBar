using System;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Pet.Gltf;

// MARK: - glTF scene controller (portable)
//
// The transport-agnostic driver over IPetGltfHost. Peer of the drive half of
// `AgentLens/PetCompanion/Render/SceneKitPetRenderer.swift` (load one model, play
// a named clip for a logical state), but expressed against the WebView2 + three.js
// bridge. It correlates commands to replies by id (peer of PretextBridge), surfaces
// the readiness heartbeat, and raises ClipEnded so the behavior graph can advance
// non-looping "react" clips back to idle.
//
// Fully exercised on the macOS authoring host against a fake IPetGltfHost
// (windows/tests/pet), the SAME way the Pretext engine is proven against
// FakePretextWebHost. The real WebView2 transport (WebView2PetGltfHost) is
// Windows/dev-host-deferred.

/// Drives a single three.js pet scene over an <see cref="IPetGltfHost"/>.
public sealed class PetGltfSceneController : IDisposable
{
    private readonly IPetGltfHost _host;
    private readonly ConcurrentDictionary<int, TaskCompletionSource<PetGltfReply>> _pending = new();
    private readonly TaskCompletionSource<bool> _ready =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    private int _nextId;
    private bool _started;
    private bool _disposed;

    public PetGltfSceneController(IPetGltfHost host)
    {
        _host = host ?? throw new ArgumentNullException(nameof(host));
        _host.MessageReceived += OnMessageReceived;
    }

    /// True once the page has posted its readiness heartbeat.
    public bool IsReady { get; private set; }

    /// The glb currently loaded (last successful <see cref="LoadModelAsync"/>).
    public string? LoadedUrl { get; private set; }

    /// The clip currently requested (last successful <see cref="PlayClipAsync"/>).
    public string? CurrentClip { get; private set; }

    /// Raised when a non-looping clip finishes in the page (peer of an animation
    /// completion callback). The behavior controller uses this to settle "react".
    public event Action<string>? ClipEnded;

    /// Raised once when the scene becomes ready.
    public event Action? Ready;

    /// Start the host and await the readiness heartbeat (idempotent).
    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (!_started)
        {
            _started = true;
            await _host.StartAsync(cancellationToken).ConfigureAwait(false);
        }
        using (cancellationToken.CanBeCanceled ? cancellationToken.Register(() => _ready.TrySetCanceled(cancellationToken)) : default)
        {
            await _ready.Task.ConfigureAwait(false);
        }
    }

    /// Load one .glb into the scene. <paramref name="draco"/> enables the
    /// DRACOLoader path for Draco-compressed clip geometry.
    public async Task LoadModelAsync(string url, bool draco = true, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(url))
        {
            throw new ArgumentException("url must be non-empty.", nameof(url));
        }
        var reply = await SendAsync(new PetGltfCommand(NextId(), PetGltfCommand.CmdLoad, url: url, draco: draco), cancellationToken)
            .ConfigureAwait(false);
        ThrowIfFailed(reply, $"load '{url}'");
        LoadedUrl = url;
    }

    /// Play a named animation clip. <paramref name="loop"/> loops it (idle/listen);
    /// non-looping clips (react/cheer) raise <see cref="ClipEnded"/> when done.
    public async Task PlayClipAsync(string name, bool loop, double crossfadeSeconds = 0.2, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            throw new ArgumentException("clip name must be non-empty.", nameof(name));
        }
        var reply = await SendAsync(
            new PetGltfCommand(NextId(), PetGltfCommand.CmdClip, name: name, loop: loop, crossfadeSeconds: crossfadeSeconds),
            cancellationToken).ConfigureAwait(false);
        ThrowIfFailed(reply, $"clip '{name}'");
        CurrentClip = name;
    }

    /// Tear the scene's model down.
    public async Task DisposeSceneAsync(CancellationToken cancellationToken = default)
    {
        var reply = await SendAsync(new PetGltfCommand(NextId(), PetGltfCommand.CmdDispose), cancellationToken)
            .ConfigureAwait(false);
        ThrowIfFailed(reply, "dispose");
        LoadedUrl = null;
        CurrentClip = null;
    }

    private int NextId() => Interlocked.Increment(ref _nextId);

    private async Task<PetGltfReply> SendAsync(PetGltfCommand command, CancellationToken cancellationToken)
    {
        var tcs = new TaskCompletionSource<PetGltfReply>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[command.Id] = tcs;
        try
        {
            await _host.PostMessageAsync(command.ToJson(), cancellationToken).ConfigureAwait(false);
            using (cancellationToken.CanBeCanceled ? cancellationToken.Register(() => tcs.TrySetCanceled(cancellationToken)) : default)
            {
                return await tcs.Task.ConfigureAwait(false);
            }
        }
        finally
        {
            _pending.TryRemove(command.Id, out _);
        }
    }

    private void OnMessageReceived(string json)
    {
        var reply = PetGltfReply.TryParse(json);
        if (reply is null)
        {
            return;
        }

        if (reply.Id == 0)
        {
            switch (reply.Event)
            {
                case PetGltfReply.EventReady:
                    if (!IsReady)
                    {
                        IsReady = true;
                        _ready.TrySetResult(true);
                        Ready?.Invoke();
                    }
                    break;
                case PetGltfReply.EventClipEnded when reply.Name is not null:
                    ClipEnded?.Invoke(reply.Name);
                    break;
            }
            return;
        }

        if (_pending.TryGetValue(reply.Id, out var tcs))
        {
            tcs.TrySetResult(reply);
        }
    }

    private static void ThrowIfFailed(PetGltfReply reply, string what)
    {
        if (!reply.Ok)
        {
            throw new PetGltfCommandException($"Pet glTF host rejected {what}: {reply.Error ?? "unknown error"}");
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _host.MessageReceived -= OnMessageReceived;
        foreach (var kv in _pending)
        {
            kv.Value.TrySetCanceled();
        }
        _pending.Clear();
        _ready.TrySetCanceled();
    }
}

/// Thrown when the glTF page rejects a command.
public sealed class PetGltfCommandException : Exception
{
    public PetGltfCommandException(string message) : base(message)
    {
    }
}
