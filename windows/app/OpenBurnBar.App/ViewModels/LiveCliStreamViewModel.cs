using System;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Dispatching;
using OpenBurnBar.App.Cli;

namespace OpenBurnBar.App.ViewModels;

/// <summary>
/// Drives an <see cref="ICliStream"/> into an observable line collection the view binds to.
/// All collection mutation is marshaled onto the captured <see cref="DispatcherQueue"/>, so
/// the stream source may resume on any thread (a real ConPTY reader will) while the UI stays
/// consistent — the streaming-state-machine seam the master plan calls out for Chat (§9.7).
/// </summary>
public sealed class LiveCliStreamViewModel : INotifyPropertyChanged
{
    private const int MaxLines = 500;

    private readonly DispatcherQueue _dispatcher;

    private ICliStream? _stream;
    private CancellationTokenSource? _cts;
    private CliLineViewModel? _openLine;
    private bool _isStreaming;
    private string _statusText = "idle";

    public LiveCliStreamViewModel(DispatcherQueue dispatcher)
    {
        _dispatcher = dispatcher;
    }

    public ObservableCollection<CliLineViewModel> Lines { get; } = new();

    /// <summary>Raised whenever a line is appended, so the view can auto-scroll to the tail.</summary>
    public event EventHandler? LineAppended;

    public bool IsStreaming
    {
        get => _isStreaming;
        private set
        {
            if (_isStreaming != value)
            {
                _isStreaming = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(CanStart));
                OnPropertyChanged(nameof(CanStop));
            }
        }
    }

    public bool CanStart => !_isStreaming;

    public bool CanStop => _isStreaming;

    public string StatusText
    {
        get => _statusText;
        private set
        {
            if (_statusText != value)
            {
                _statusText = value;
                OnPropertyChanged();
            }
        }
    }

    /// <summary>Bind a source without starting it.</summary>
    public void SetStream(ICliStream stream) => _stream = stream;

    /// <summary>Start pumping the bound stream. No-op if already streaming or unbound.</summary>
    public void Start()
    {
        if (_isStreaming || _stream is null)
        {
            return;
        }

        _cts = new CancellationTokenSource();
        IsStreaming = true;
        StatusText = "streaming";
        _ = PumpAsync(_stream, _cts.Token);
    }

    /// <summary>Stop pumping and cancel the source.</summary>
    public void Stop()
    {
        if (!_isStreaming)
        {
            return;
        }

        _cts?.Cancel();
        IsStreaming = false;
        StatusText = "stopped";
        _openLine = null;
    }

    private async Task PumpAsync(ICliStream stream, CancellationToken token)
    {
        try
        {
            // The source may resume on any thread (a real ConPTY reader will), so marshal the
            // WHOLE parse+append onto the UI thread — that keeps _openLine and Lines single-threaded.
            await foreach (var evt in stream.ReadAsync(token).ConfigureAwait(false))
            {
                var captured = evt;
                _dispatcher.TryEnqueue(() => Ingest(captured));
            }
        }
        catch (OperationCanceledException)
        {
            // Normal stop.
        }
        finally
        {
            _dispatcher.TryEnqueue(() =>
            {
                if (IsStreaming)
                {
                    IsStreaming = false;
                    StatusText = "ended";
                }
            });
        }
    }

    /// <summary>
    /// Split a chunk on newlines: each newline closes the open line; the trailing remainder
    /// (if any) stays open for the next chunk. Keeps a line's kind fixed to when it opened.
    /// Runs on the UI thread (dispatched from <see cref="PumpAsync"/>).
    /// </summary>
    private void Ingest(CliStreamEvent evt)
    {
        string text = evt.Text;
        int start = 0;
        for (int i = 0; i < text.Length; i++)
        {
            if (text[i] == '\n')
            {
                AppendToOpen(evt.Kind, text.Substring(start, i - start));
                _openLine = null; // newline closes the current line
                start = i + 1;
            }
        }

        if (start < text.Length)
        {
            AppendToOpen(evt.Kind, text.Substring(start));
        }
    }

    private void AppendToOpen(CliStreamEventKind kind, string segment)
    {
        if (_openLine is null)
        {
            _openLine = new CliLineViewModel(kind, segment);
            Lines.Add(_openLine);
            TrimBacklog();
        }
        else
        {
            _openLine.Append(segment);
        }

        LineAppended?.Invoke(this, EventArgs.Empty);
    }

    private void TrimBacklog()
    {
        while (Lines.Count > MaxLines)
        {
            Lines.RemoveAt(0);
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
