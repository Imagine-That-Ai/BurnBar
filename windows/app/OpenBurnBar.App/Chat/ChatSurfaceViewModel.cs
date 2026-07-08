using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Presentation.Chat;
using OpenBurnBar.App.Configuration;

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
    private readonly Dictionary<string, ChatMessageViewModel> _index = new();

    private CancellationTokenSource? _cts;
    private string _inputText = string.Empty;
    private readonly string _backendLabel;

    public ChatSurfaceViewModel(IChatStreamDriver? driver = null, string backendLabel = "hermes")
    {
        _driver = driver ?? (RuntimeDataMode.SampleModeEnabled
            ? new ScriptedChatStreamDriver()
            : new UnavailableChatStreamDriver());
        _backendLabel = backendLabel;

        Messages = new ObservableCollection<ChatMessageViewModel>();
        SendCommand = new RelayCommand(() => _ = SendAsync(), () => CanSend);
        StopCommand = new RelayCommand(() => _machine.CancelGeneration(), () => IsStreaming);
        RegenerateCommand = new RelayCommand(() => _ = RegenerateAsync(), () => CanRegenerate);

        _machine.Changed += OnMachineChanged;
        _machine.CancelRequested += () => _cts?.Cancel();
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

    public bool CanSend => !_machine.IsSendBusy && !string.IsNullOrWhiteSpace(InputText);

    public bool CanRegenerate =>
        !_machine.IsSendBusy
        && _machine.Messages.Count > 0
        && _machine.Messages[^1].Role == ChatMessageRole.Assistant;

    // MARK: - Commands

    private async Task SendAsync()
    {
        var user = _machine.TryBeginUserTurn(InputText);
        if (user is null)
        {
            return;
        }
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
        try
        {
            await foreach (var streamEvent in _driver
                .StreamAsync(userText, _machine.Messages, _cts.Token)
                .ConfigureAwait(true))
            {
                _machine.Ingest(streamEvent);
            }
            _machine.CompleteStream();
        }
        catch (OperationCanceledException)
        {
            // CancelGeneration already settled the machine as a cancelled failure.
        }
        catch (Exception ex)
        {
            _machine.FailStream(cancelled: false, errorMessage: ex.Message);
        }
        finally
        {
            _cts?.Dispose();
            _cts = null;
            RaiseCommandStates();
        }
    }

    // MARK: - Reconciliation

    private void OnMachineChanged()
    {
        Reconcile();
        Raise(nameof(IsStreaming));
        Raise(nameof(IsEmpty));
        RaiseCommandStates();
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
