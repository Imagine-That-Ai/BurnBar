using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Chat;

namespace OpenBurnBar.App.Chat;

// MARK: - Chat surface view-model
//
// The WinUI binding surface over the PORTABLE ChatSessionStateMachine. It owns:
//   • the ObservableCollection the atom-router ItemsRepeater binds to,
//   • the composer state (input text, Send/Stop/Regenerate commands),
//   • the streaming drive loop that pumps IChatStreamDriver events into the
//     machine and reconciles the message VMs on every tick.
//
// All the actual transition logic lives in ChatSessionStateMachine (unit-tested
// on macOS). This class is the thin, ceiling-limited WinUI adapter.

public sealed class ChatSurfaceViewModel : INotifyPropertyChanged
{
    private readonly ChatSessionStateMachine _machine = new();
    private readonly IChatStreamDriver _driver;
    private readonly IChatConversationStore _store;
    private readonly Dictionary<string, ChatMessageViewModel> _index = new();

    private CancellationTokenSource? _cts;
    private string _inputText = string.Empty;
    private readonly string _backendLabel;
    private string _threadId = Guid.NewGuid().ToString();
    private string? _persistenceWarning;
    private readonly List<ChatAttachmentRecord> _pendingAttachments = new();
    private string _workspaceRoot = DefaultWorkspaceRoot();

    public ChatSurfaceViewModel(
        IChatStreamDriver? driver = null,
        string backendLabel = "hermes",
        IChatConversationStore? store = null)
    {
        _driver = driver ?? ChatStreamDriverFactory.CreateDefault();
        _store = store ?? ChatConversationStoreFactory.CreateDefault();
        _backendLabel = backendLabel;

        Messages = new ObservableCollection<ChatMessageViewModel>();
        SendCommand = new RelayCommand(() => _ = SendAsync(), () => CanSend);
        StopCommand = new RelayCommand(() => _machine.CancelGeneration(), () => IsStreaming);
        RegenerateCommand = new RelayCommand(() => _ = RegenerateAsync(), () => CanRegenerate);

        _machine.Changed += OnMachineChanged;
        _machine.CancelRequested += () => _cts?.Cancel();
        RecoverLastThread();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public ObservableCollection<ChatMessageViewModel> Messages { get; }

    public RelayCommand SendCommand { get; }

    public RelayCommand StopCommand { get; }

    public RelayCommand RegenerateCommand { get; }

    /// The Pretext engine the streaming bubbles measure against. Set by the view
    /// once its offscreen WebView2 host is ready; null until then (bubbles fall
    /// back to their intrinsic layout).
    public OpenBurnBar.Pretext.PretextEngine? PretextEngine { get; set; }

    public string InputText
    {
        get => _inputText;
        set
        {
            if (_inputText != value)
            {
                _inputText = value;
                Raise(nameof(InputText));
                SendCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool IsStreaming => _machine.IsStreaming;

    public bool IsEmpty => Messages.Count == 0;

    public bool HasFailure => _machine.LastFailureKind is not null || !string.IsNullOrWhiteSpace(_machine.StreamError);

    public string FailureText
    {
        get
        {
            if (_machine.LastFailureKind is null && string.IsNullOrWhiteSpace(_machine.StreamError))
            {
                return string.Empty;
            }

            string kind = _machine.LastFailureKind?.ToString() ?? "StreamError";
            return string.IsNullOrWhiteSpace(_machine.StreamError)
                ? kind
                : kind + ": " + _machine.StreamError;
        }
    }

    public bool HasPersistenceWarning => !string.IsNullOrWhiteSpace(_persistenceWarning);

    public string PersistenceWarning => _persistenceWarning ?? string.Empty;

    public bool CanSend => !_machine.IsSendBusy
        && (!string.IsNullOrWhiteSpace(InputText) || _pendingAttachments.Count > 0);

    public bool HasPendingAttachments => _pendingAttachments.Count > 0;

    public string PendingAttachmentSummary =>
        _pendingAttachments.Count == 0
            ? string.Empty
            : string.Join(", ", _pendingAttachments.Select(attachment => attachment.DisplayName));

    public bool CanRegenerate =>
        !_machine.IsSendBusy
        && _machine.Messages.Count > 0
        && _machine.Messages[^1].Role == ChatMessageRole.Assistant;

    // MARK: - Commands

    private async Task SendAsync()
    {
        var user = _machine.TryBeginUserTurnWithAttachments(InputText, _pendingAttachments.ToArray());
        if (user is null)
        {
            return;
        }
        _pendingAttachments.Clear();
        Raise(nameof(HasPendingAttachments));
        Raise(nameof(PendingAttachmentSummary));
        Raise(nameof(CanSend));
        InputText = string.Empty;
        await RunTurnAsync(user.Content).ConfigureAwait(true);
    }

    private async Task RegenerateAsync()
    {
        var userText = _machine.PrepareRegeneration();
        if (userText is null)
        {
            return;
        }
        await RunTurnAsync(userText).ConfigureAwait(true);
    }

    private async Task RunTurnAsync(string userText)
    {
        _machine.BeginAssistantStream(_backendLabel);
        _cts = new CancellationTokenSource();
        RaiseCommandStates();
        var terminalFromStreamEvent = false;
        try
        {
            await foreach (var streamEvent in _driver
                .StreamAsync(userText, _machine.Messages, _cts.Token)
                .ConfigureAwait(true))
            {
                _machine.Ingest(streamEvent);
                if (streamEvent is ChatStreamEvent.StreamFailure)
                {
                    terminalFromStreamEvent = true;
                    break;
                }
            }
            if (!terminalFromStreamEvent
                && _machine.Phase != ChatStreamPhase.Failed
                && _machine.Phase != ChatStreamPhase.Cancelled)
            {
                _machine.CompleteStream();
            }
        }
        catch (OperationCanceledException)
        {
            // CancelGeneration already settled the machine as a cancelled failure.
        }
        catch (Exception ex)
        {
            _machine.FailStream(cancelled: false, ChatFailureKind.StreamError, ex.Message);
        }
        finally
        {
            _cts?.Dispose();
            _cts = null;
            PersistCurrentTranscript();
            RaiseCommandStates();
        }
    }

    // MARK: - Reconciliation

    private void OnMachineChanged()
    {
        Reconcile();
        PersistCurrentTranscript();
        Raise(nameof(IsStreaming));
        Raise(nameof(IsEmpty));
        Raise(nameof(HasFailure));
        Raise(nameof(FailureText));
        RaiseCommandStates();
    }

    private void RecoverLastThread()
    {
        try
        {
            ChatThreadSnapshot snapshot = _store.LoadMostRecentThread();
            _threadId = snapshot.ThreadId;
            if (snapshot.Messages.Count > 0)
            {
                _machine.LoadTranscript(snapshot.Messages);
            }
        }
        catch (Exception ex)
        {
            SetPersistenceWarning("Chat history could not be reopened: " + ex.Message);
        }
    }

    private void PersistCurrentTranscript()
    {
        try
        {
            _store.SaveMessages(
                _threadId,
                _machine.Messages,
                _machine.LastFailureKind,
                _machine.StreamError);
            SetPersistenceWarning(null);
        }
        catch (Exception ex)
        {
            SetPersistenceWarning("Chat history is not being saved: " + ex.Message);
        }
    }

    private void SetPersistenceWarning(string? warning)
    {
        if (_persistenceWarning == warning)
        {
            return;
        }

        _persistenceWarning = warning;
        Raise(nameof(HasPersistenceWarning));
        Raise(nameof(PersistenceWarning));
    }

    public void StageAttachmentFromFile(string path)
    {
        ChatAttachmentRecord attachment = WindowsChatAttachmentStager.ImportFile(path, _workspaceRoot);
        _pendingAttachments.Add(attachment);
        Raise(nameof(HasPendingAttachments));
        Raise(nameof(PendingAttachmentSummary));
        Raise(nameof(CanSend));
        SendCommand.RaiseCanExecuteChanged();
    }

    public void StagePastedText(string text, string? suggestedName = null)
    {
        ChatAttachmentRecord attachment = WindowsChatAttachmentStager.ImportPastedText(text, _workspaceRoot, suggestedName);
        _pendingAttachments.Add(attachment);
        Raise(nameof(HasPendingAttachments));
        Raise(nameof(PendingAttachmentSummary));
        Raise(nameof(CanSend));
        SendCommand.RaiseCanExecuteChanged();
    }

    internal void ConfigureWorkspaceForTests(string workspaceRoot)
    {
        _workspaceRoot = workspaceRoot;
    }

    private static string DefaultWorkspaceRoot()
    {
        string? local = Environment.GetEnvironmentVariable("LOCALAPPDATA");
        string root = !string.IsNullOrWhiteSpace(local)
            ? Path.Combine(local, "OpenBurnBar")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".openburnbar");
        return Path.Combine(root, "chat-workspaces", "default");
    }

    private void Reconcile()
    {
        var current = _machine.Messages;
        var live = new HashSet<string>();
        foreach (var record in current)
        {
            live.Add(record.Id);
        }

        // Prune VMs whose records are gone (e.g. regenerate dropped the assistant).
        for (var i = Messages.Count - 1; i >= 0; i--)
        {
            if (!live.Contains(Messages[i].Id))
            {
                _index.Remove(Messages[i].Id);
                Messages.RemoveAt(i);
            }
        }

        // Add + refresh in record order.
        for (var i = 0; i < current.Count; i++)
        {
            var record = current[i];
            if (!_index.TryGetValue(record.Id, out var vm))
            {
                vm = new ChatMessageViewModel(record);
                _index[record.Id] = vm;
                if (i < Messages.Count)
                {
                    Messages.Insert(i, vm);
                }
                else
                {
                    Messages.Add(vm);
                }
            }
            vm.Refresh(_machine.IsStreaming);
        }
    }

    private void RaiseCommandStates()
    {
        Raise(nameof(CanSend));
        Raise(nameof(CanRegenerate));
        SendCommand.RaiseCanExecuteChanged();
        StopCommand.RaiseCanExecuteChanged();
        RegenerateCommand.RaiseCanExecuteChanged();
    }

    private void Raise(string name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
