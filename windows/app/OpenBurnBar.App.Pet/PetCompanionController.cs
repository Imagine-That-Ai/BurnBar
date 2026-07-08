using System;
using OpenBurnBar.App.Pet.Behavior;
using OpenBurnBar.App.Pet.Chat;
using OpenBurnBar.App.Pet.Definition;
using OpenBurnBar.App.Pet.Gltf;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Pet;

// MARK: - PetCompanion controller (portable orchestrator)
//
// The portable brain of the desktop pet, peer of
// `AgentLens/PetCompanion/Shell/PetCompanionController.swift`. It wires the four
// pieces this lane builds:
//
//   • BehaviorInterpreter   — the behavior-graph state (idle/listen/think/…)
//   • PetChatEventBridge     — drives the graph from the LANDED Chat state machine
//   • PetClipResolver        — logical node -> concrete clip for the loaded pet
//   • PetGltfSceneController  — (optional) pushes the clip into the three.js scene
//
// and exposes the coarse Activity (idle / active / summon) the WinUI overlay reacts
// to for its window level + hit-test policy. No WinUI / Win32 dependency: the whole
// thing runs + is unit-tested on the macOS host; the WinUI overlay is a thin shell
// over this controller.

/// Portable orchestrator for one running pet.
public sealed class PetCompanionController : IDisposable
{
    private readonly PetClipResolver _resolver;
    private readonly PetGltfSceneController? _scene;
    private bool _summoned;
    private bool _disposed;
    private PetActivityState _lastActivity;

    public PetCompanionController(
        PetBehaviorGraph graph,
        ChatSessionStateMachine chat,
        PetDefinition? definition = null,
        PetGltfSceneController? scene = null,
        uint seed = 1)
    {
        if (graph is null)
        {
            throw new ArgumentNullException(nameof(graph));
        }
        if (chat is null)
        {
            throw new ArgumentNullException(nameof(chat));
        }
        Interpreter = new BehaviorInterpreter(graph, seed);
        Bridge = new PetChatEventBridge(Interpreter, chat);
        _resolver = new PetClipResolver(definition);
        _scene = scene;

        Interpreter.StateChanged += OnLogicalStateChanged;
        if (_scene is not null)
        {
            _scene.ClipEnded += OnClipEnded;
        }

        CurrentClip = _resolver.Resolve(Interpreter.Current);
        _lastActivity = Activity;
    }

    /// The behavior-graph interpreter (exposed for the overlay + tests).
    public BehaviorInterpreter Interpreter { get; }

    /// The chat-event bridge (Notify* passthroughs for OS senses).
    public PetChatEventBridge Bridge { get; }

    /// The current logical node the graph is in.
    public string CurrentLogicalNode => Interpreter.Current;

    /// The concrete clip resolved for the current node (null when the pet carries no
    /// clips).
    public string? CurrentClip { get; private set; }

    /// The coarse activity the overlay reacts to. A live summon overrides the
    /// logical-node classification.
    public PetActivityState Activity => _summoned ? PetActivityState.Summon : PetActivity.Classify(Interpreter.Current);

    /// Raised when <see cref="Activity"/> changes.
    public event Action<PetActivityState>? ActivityChanged;

    /// Raised when <see cref="CurrentClip"/> changes (the overlay/scene should play
    /// the new clip).
    public event Action<string>? ClipChanged;

    /// Summon the pet to the user (hotkey / cursor pull). Sets Activity to
    /// <see cref="PetActivityState.Summon"/> and pulls the graph toward an engaged
    /// state (cursorNear: idle -> listen). Idempotent.
    public void Summon()
    {
        _summoned = true;
        // Bring the pet forward; cursorNear is the graph's "come here" edge (this may
        // fire OnLogicalStateChanged, which re-checks activity — the delta guard keeps
        // it from double-signalling).
        Bridge.NotifyCursorNear();
        SignalActivityIfChanged();
    }

    /// Release a summon; Activity reverts to the current node's classification.
    public void ReleaseSummon()
    {
        if (!_summoned)
        {
            return;
        }
        _summoned = false;
        SignalActivityIfChanged();
    }

    private void OnLogicalStateChanged(string node)
    {
        var clip = _resolver.Resolve(node);
        if (clip is not null && !string.Equals(clip, CurrentClip, StringComparison.Ordinal))
        {
            CurrentClip = clip;
            ClipChanged?.Invoke(clip);
            _ = PlayCurrentClipAsync(node, clip);
        }

        SignalActivityIfChanged();
    }

    // Recompute Activity and raise ActivityChanged only on a real transition.
    private void SignalActivityIfChanged()
    {
        var now = Activity;
        if (now != _lastActivity)
        {
            _lastActivity = now;
            ActivityChanged?.Invoke(now);
        }
    }

    private async System.Threading.Tasks.Task PlayCurrentClipAsync(string node, string clip)
    {
        if (_scene is null || !_scene.IsReady)
        {
            return;
        }
        try
        {
            await _scene.PlayClipAsync(clip, PetClipResolver.ShouldLoop(node)).ConfigureAwait(false);
        }
        catch (PetGltfCommandException)
        {
            // Best-effort: a rejected clip must not crash the pet brain.
        }
        catch (OperationCanceledException)
        {
            // scene torn down
        }
    }

    private void OnClipEnded(string clip)
    {
        // A one-shot "react" clip finished -> settle the graph back down
        // (react -> idle on cooldownElapsed in the shared graphs).
        if (string.Equals(Interpreter.Current, "react", StringComparison.Ordinal))
        {
            Bridge.NotifyCooldownElapsed();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Interpreter.StateChanged -= OnLogicalStateChanged;
        if (_scene is not null)
        {
            _scene.ClipEnded -= OnClipEnded;
        }
        Bridge.Dispose();
    }
}
