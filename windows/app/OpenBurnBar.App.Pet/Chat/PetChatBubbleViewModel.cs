using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using OpenBurnBar.App.Pet.Behavior;
using OpenBurnBar.App.Pet.Reaction;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Pet.Chat;

// MARK: - Pet chat bubble view-model
//
// The view-model behind the pet's speech bubble, peer of
// `AgentLens/PetCompanion/Chat/PetChatBubble.swift`. It REUSES the LANDED portable
// Chat view-model verbatim — it composes a ChatSessionStateMachine (the exact same
// type the WinUI DashboardChatWorkspace binds) rather than re-implementing a chat
// model — and layers the pet-specific behaviour on top:
//
//   • classifies each outgoing message (PetReactionBrain.ClassifyMessage) and
//     records it as the pet's LastUserIntent so the reaction brain can pick a
//     matching clip,
//   • forwards input focus/blur to the pet's behavior graph (inputFocused / …),
//   • re-broadcasts the chat's Changed pulse as INotifyPropertyChanged so a WinUI
//     bubble can x:Bind to Messages / IsStreaming without knowing about the state
//     machine internals.
//
// No WinUI dependency: this is unit-tested on macOS, and the WinUI bubble
// (windows/app/.../Pet/PetChatBubbleView.xaml) is a thin render of it.

/// View-model for the pet's chat bubble; wraps the landed Chat state machine.
public sealed class PetChatBubbleViewModel : INotifyPropertyChanged, IDisposable
{
    private readonly PetCompanionController _pet;
    private string _draftText = string.Empty;
    private bool _inputFocused;
    private bool _disposed;

    public PetChatBubbleViewModel(ChatSessionStateMachine chat, PetCompanionController pet)
    {
        Chat = chat ?? throw new ArgumentNullException(nameof(chat));
        _pet = pet ?? throw new ArgumentNullException(nameof(pet));
        Chat.Changed += OnChatChanged;
    }

    /// The landed portable Chat state machine this bubble renders.
    public ChatSessionStateMachine Chat { get; }

    /// The ordered transcript the bubble shows (peer of the chat surface's Messages).
    public IReadOnlyList<ChatMessageRecord> Messages => Chat.Messages;

    /// True while an assistant turn is streaming (drives the bubble's typing dots).
    public bool IsStreaming => Chat.IsStreaming;

    /// True while any send is in flight or streaming (disables the send button).
    public bool IsSendBusy => Chat.IsSendBusy;

    /// The coarse pet activity, forwarded for the bubble's glow.
    public PetActivityState PetActivity => _pet.Activity;

    /// The classified intent of the last user message (feeds the reaction brain).
    public PetMessageIntent? LastUserIntent { get; private set; }

    /// The composer draft text.
    public string DraftText
    {
        get => _draftText;
        set
        {
            if (!string.Equals(_draftText, value, StringComparison.Ordinal))
            {
                _draftText = value ?? string.Empty;
                RaisePropertyChanged();
            }
        }
    }

    /// The chat input gained focus → perk the pet to listen.
    public void NotifyInputFocused()
    {
        if (_inputFocused)
        {
            return;
        }
        _inputFocused = true;
        _pet.Bridge.NotifyInputFocused();
    }

    /// The chat input lost focus → let the pet drift back down after idle.
    public void NotifyInputBlurred()
    {
        _inputFocused = false;
    }

    /// Begin a user turn: classify the intent, record it for the pet, and append the
    /// user message via the LANDED state machine (the platform driver then starts the
    /// backend stream + BeginAssistantStream, which the pet bridge observes). Returns
    /// the appended record, or null when the draft is empty or a send is already busy.
    public ChatMessageRecord? BeginUserTurn()
    {
        var text = DraftText;
        LastUserIntent = PetReactionBrain.ClassifyMessage(text);
        var record = Chat.TryBeginUserTurn(text);
        if (record is not null)
        {
            DraftText = string.Empty;
        }
        return record;
    }

    private void OnChatChanged()
    {
        RaisePropertyChanged(nameof(Messages));
        RaisePropertyChanged(nameof(IsStreaming));
        RaisePropertyChanged(nameof(IsSendBusy));
        RaisePropertyChanged(nameof(PetActivity));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void RaisePropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Chat.Changed -= OnChatChanged;
    }
}
