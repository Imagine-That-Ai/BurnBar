using System;
using OpenBurnBar.App.Pet.Behavior;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Pet.Chat;

// MARK: - Chat-event bridge
//
// The glue that makes "named transitions fire on named chat events" real: it
// observes the LANDED portable Chat state machine
// (OpenBurnBar.App.Presentation.Chat.ChatSessionStateMachine — the same VM the
// WinUI chat surface drives) and fires the behavior-graph triggers on a
// BehaviorInterpreter as the turn walks its lifecycle:
//
//   user send      (SendInFlight false->true)  -> sendPressed   (listen -> think)
//   first token    (Phase -> Streaming)         -> streamStart   (think  -> speak)
//   more tokens    (StreamingTick advances)      -> streamToken   (speak stays)
//   turn settles   (StreamSettled: completed)    -> resultLanded  (speak  -> react)
//   turn fails     (StreamSettled: !cancelled)   -> resultLanded  (speak  -> react; sad clip)
//   turn cancelled (StreamSettled: cancelled)    -> (no trigger; partial stays)
//
// The ambient guards the chat VM does not model — cursorNear / inputFocused /
// cooldownElapsed / idleElapsed / fallbackFired / special — are fired directly by
// the PetCompanionController from OS senses through the Notify* passthroughs here,
// so ALL trigger routing goes through one auditable seam.
//
// This is the peer of the reaction wiring in
// `AgentLens/PetCompanion/Chat/PetChatProvider.swift` +
// `AgentLens/PetCompanion/Core/PetReactionBrain.swift`'s outcome hooks.

/// Translates a <see cref="ChatSessionStateMachine"/> lifecycle into behavior-graph
/// triggers on a <see cref="BehaviorInterpreter"/>.
public sealed class PetChatEventBridge : IDisposable
{
    private readonly BehaviorInterpreter _interpreter;
    private readonly ChatSessionStateMachine _chat;

    private bool _prevSendInFlight;
    private ChatStreamPhase _prevPhase;
    private int _prevTick;
    private bool _disposed;

    public PetChatEventBridge(BehaviorInterpreter interpreter, ChatSessionStateMachine chat)
    {
        _interpreter = interpreter ?? throw new ArgumentNullException(nameof(interpreter));
        _chat = chat ?? throw new ArgumentNullException(nameof(chat));

        _prevSendInFlight = chat.SendInFlight;
        _prevPhase = chat.Phase;
        _prevTick = chat.StreamingTick;

        _chat.Changed += OnChatChanged;
        _chat.StreamSettled += OnStreamSettled;
    }

    /// Raised after every trigger this bridge fires. Arguments: the trigger, and the
    /// interpreter's new node (null when the trigger matched no transition).
    public event Action<PetBehaviorTrigger, string?>? TriggerFired;

    // ── Ambient (OS-sense) passthroughs the controller drives ────────────────────

    /// Chat input gained focus → the pet should perk to listen (react -> listen).
    public void NotifyInputFocused() => Fire(PetBehaviorTrigger.InputFocused);

    /// The cursor entered the pet's proximity radius (idle -> listen).
    public void NotifyCursorNear() => Fire(PetBehaviorTrigger.CursorNear);

    /// The wander/ambient cooldown elapsed (time-driven weighted beat).
    public void NotifyCooldownElapsed() => Fire(PetBehaviorTrigger.CooldownElapsed);

    /// Long idle / display asleep (listen -> idle).
    public void NotifyIdleElapsed() => Fire(PetBehaviorTrigger.IdleElapsed);

    /// The deterministic local-persona fallback fired (speak -> react).
    public void NotifyFallbackFired() => Fire(PetBehaviorTrigger.FallbackFired);

    /// A rare "special" ambient beat.
    public void NotifySpecial() => Fire(PetBehaviorTrigger.Special);

    // ── Chat-driven translation ───────────────────────────────────────────────────

    private void OnChatChanged()
    {
        // user pressed send (reentrancy sentinel armed) -> sendPressed
        if (!_prevSendInFlight && _chat.SendInFlight)
        {
            Fire(PetBehaviorTrigger.SendPressed);
        }

        // first assistant token / stream began -> streamStart
        if (_prevPhase != ChatStreamPhase.Streaming && _chat.Phase == ChatStreamPhase.Streaming)
        {
            Fire(PetBehaviorTrigger.StreamStart);
        }
        // subsequent tokens while still streaming -> streamToken
        else if (_chat.Phase == ChatStreamPhase.Streaming && _chat.StreamingTick != _prevTick)
        {
            Fire(PetBehaviorTrigger.StreamToken);
        }

        _prevSendInFlight = _chat.SendInFlight;
        _prevPhase = _chat.Phase;
        _prevTick = _chat.StreamingTick;
    }

    private void OnStreamSettled(ChatStreamSettleOutcome outcome)
    {
        // Keep the delta tracker consistent with the terminal phase so a follow-on
        // Changed does not double-fire.
        _prevPhase = _chat.Phase;
        _prevSendInFlight = _chat.SendInFlight;
        _prevTick = _chat.StreamingTick;

        if (outcome.Cancelled)
        {
            // Stop pressed: the partial answer stays; the pet does not "land" a
            // result — it settles via the ambient idleElapsed path instead.
            return;
        }
        // Both a clean completion and a genuine failure land a result the pet reacts
        // to (the reaction brain picks a celebratory vs sad clip from the outcome).
        Fire(PetBehaviorTrigger.ResultLanded);
    }

    private void Fire(PetBehaviorTrigger trigger)
    {
        var newState = _interpreter.Fire(trigger);
        TriggerFired?.Invoke(trigger, newState);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _chat.Changed -= OnChatChanged;
        _chat.StreamSettled -= OnStreamSettled;
    }
}
