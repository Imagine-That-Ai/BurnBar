using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Mission;

public sealed record TelegramBridgeConfiguration(
    bool IsEnabled,
    string BotToken,
    string ChatId,
    TimeSpan PollInterval,
    int DefaultSnoozeMinutes = 180)
{
    public static TelegramBridgeConfiguration Disabled { get; } =
        new(false, string.Empty, string.Empty, TimeSpan.FromSeconds(5));

    public bool IsConfigured =>
        IsEnabled
        && !string.IsNullOrWhiteSpace(BotToken)
        && !string.IsNullOrWhiteSpace(ChatId);
}

public enum TelegramCommand
{
    Help,
    Pending,
    Followups,
    Done,
    Snooze,
    Calendar,
    Answer,
    Latest,
    Status,
    RunDaily,
    RunWeekly,
}

public sealed record TelegramCommandRequest(
    TelegramCommand Command,
    IReadOnlyList<string> Arguments,
    string Actor = "telegram");

public sealed record TelegramCommandResponse(bool Ok, string Message);

public static class TelegramCommandParser
{
    public static TelegramCommandRequest? Parse(string text, string actor = "telegram")
    {
        string value = (text ?? string.Empty).Trim();
        if (value.Length == 0)
        {
            return null;
        }

        string[] parts = value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0)
        {
            return null;
        }

        string commandName = parts[0].Trim('/').ToLowerInvariant();
        TelegramCommand? command = commandName switch
        {
            "help" => TelegramCommand.Help,
            "pending" => TelegramCommand.Pending,
            "followups" => TelegramCommand.Followups,
            "done" => TelegramCommand.Done,
            "snooze" => TelegramCommand.Snooze,
            "calendar" => TelegramCommand.Calendar,
            "answer" => TelegramCommand.Answer,
            "latest" => TelegramCommand.Latest,
            "status" => TelegramCommand.Status,
            "daily" or "run_daily" => TelegramCommand.RunDaily,
            "weekly" or "run_weekly" => TelegramCommand.RunWeekly,
            _ => null,
        };
        if (!command.HasValue)
        {
            return null;
        }

        return new TelegramCommandRequest(command.Value, parts.Skip(1).ToArray(), actor);
    }
}

public interface ITelegramUpdateOffsetStore
{
    ValueTask<long?> LoadAsync(CancellationToken cancellationToken = default);

    ValueTask SaveAsync(long offset, CancellationToken cancellationToken = default);
}

public sealed class InMemoryTelegramUpdateOffsetStore : ITelegramUpdateOffsetStore
{
    private long _offset;

    public InMemoryTelegramUpdateOffsetStore(long? offset = null)
    {
        _offset = offset ?? -1;
    }

    public ValueTask<long?> LoadAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        long value = Interlocked.Read(ref _offset);
        return ValueTask.FromResult<long?>(value < 0 ? null : value);
    }

    public ValueTask SaveAsync(long offset, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Interlocked.Exchange(ref _offset, offset);
        return ValueTask.CompletedTask;
    }
}

/// <summary>
/// Atomic non-secret persistence for Telegram's monotonic update offset.
/// </summary>
public sealed class JsonFileTelegramUpdateOffsetStore : ITelegramUpdateOffsetStore
{
    private const int MaximumFileBytes = 1024;
    private readonly string _path;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public JsonFileTelegramUpdateOffsetStore(string path)
    {
        _path = Path.GetFullPath(
            string.IsNullOrWhiteSpace(path)
                ? throw new ArgumentException("A Telegram offset path is required.", nameof(path))
                : path);
    }

    public async ValueTask<long?> LoadAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (!File.Exists(_path))
            {
                return null;
            }

            var info = new FileInfo(_path);
            if (info.Length is <= 0 or > MaximumFileBytes)
            {
                return null;
            }

            byte[] bytes = await File.ReadAllBytesAsync(_path, cancellationToken).ConfigureAwait(false);
            using JsonDocument document = JsonDocument.Parse(bytes);
            return document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("offset", out JsonElement offset)
                && offset.TryGetInt64(out long value)
                && value >= 0
                    ? value
                    : null;
        }
        catch (JsonException)
        {
            return null;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async ValueTask SaveAsync(long offset, CancellationToken cancellationToken = default)
    {
        if (offset < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(offset));
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            string? directory = Path.GetDirectoryName(_path);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(new { offset });
            string temporary = $"{_path}.{Guid.NewGuid():N}.tmp";
            try
            {
                await File.WriteAllBytesAsync(temporary, bytes, cancellationToken).ConfigureAwait(false);
                File.Move(temporary, _path, overwrite: true);
            }
            finally
            {
                try { File.Delete(temporary); } catch { /* best effort */ }
            }
        }
        finally
        {
            _gate.Release();
        }
    }
}

/// <summary>
/// Lifecycle-owned Telegram command poller. Settings are reloaded each cycle,
/// offsets advance before command execution, and only the configured chat can
/// reach the injected Mission Control command handler.
/// </summary>
public sealed class TelegramPollingService : IAsyncDisposable
{
    private static readonly TimeSpan MinimumPollInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan MaximumPollInterval = TimeSpan.FromMinutes(5);

    private readonly ITelegramBotClient _client;
    private readonly Func<TelegramBridgeConfiguration> _configurationProvider;
    private readonly ITelegramUpdateOffsetStore _offsetStore;
    private readonly Func<TelegramCommandRequest, CancellationToken, Task<TelegramCommandResponse>> _commandHandler;
    private readonly Func<int, CancellationToken, Task<IReadOnlyList<string>>>? _dueMessageProvider;
    private readonly Action<Exception>? _errorSink;
    private readonly SemaphoreSlim _pollGate = new(1, 1);
    private CancellationTokenSource? _cancellation;
    private Task? _loop;

    public TelegramPollingService(
        ITelegramBotClient client,
        Func<TelegramBridgeConfiguration> configurationProvider,
        ITelegramUpdateOffsetStore offsetStore,
        Func<TelegramCommandRequest, CancellationToken, Task<TelegramCommandResponse>> commandHandler,
        Func<int, CancellationToken, Task<IReadOnlyList<string>>>? dueMessageProvider = null,
        Action<Exception>? errorSink = null)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _configurationProvider = configurationProvider
            ?? throw new ArgumentNullException(nameof(configurationProvider));
        _offsetStore = offsetStore ?? throw new ArgumentNullException(nameof(offsetStore));
        _commandHandler = commandHandler ?? throw new ArgumentNullException(nameof(commandHandler));
        _dueMessageProvider = dueMessageProvider;
        _errorSink = errorSink;
    }

    public bool IsRunning => _loop is { IsCompleted: false };

    public void Start()
    {
        if (_loop is not null)
        {
            return;
        }

        _cancellation = new CancellationTokenSource();
        _loop = Task.Run(() => RunAsync(_cancellation.Token));
    }

    public async Task PollOnceAsync(CancellationToken cancellationToken = default)
    {
        if (!await _pollGate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        {
            return;
        }

        try
        {
            TelegramBridgeConfiguration configuration = _configurationProvider();
            if (!configuration.IsConfigured)
            {
                return;
            }

            if (_dueMessageProvider is not null)
            {
                IReadOnlyList<string> messages = await _dueMessageProvider(
                    Math.Clamp(configuration.DefaultSnoozeMinutes, 15, 7 * 24 * 60),
                    cancellationToken).ConfigureAwait(false);
                foreach (string message in messages.Take(100))
                {
                    await _client.SendAsync(
                        configuration.BotToken,
                        configuration.ChatId,
                        NormalizeResponse(message),
                        cancellationToken).ConfigureAwait(false);
                }
            }

            long? offset = await _offsetStore.LoadAsync(cancellationToken).ConfigureAwait(false);
            IReadOnlyList<TelegramInboundMessage> updates = await _client
                .FetchUpdatesAsync(configuration.BotToken, offset, cancellationToken)
                .ConfigureAwait(false);
            foreach (TelegramInboundMessage update in updates.OrderBy(item => item.UpdateId))
            {
                if (update.UpdateId == long.MaxValue)
                {
                    throw new TelegramBotException("Telegram update ID exceeded the supported range.");
                }

                await _offsetStore.SaveAsync(update.UpdateId + 1, cancellationToken).ConfigureAwait(false);
                if (!string.Equals(update.ChatId, configuration.ChatId.Trim(), StringComparison.Ordinal)
                    || TelegramCommandParser.Parse(update.Text) is not TelegramCommandRequest command)
                {
                    continue;
                }

                TelegramCommandResponse response = await _commandHandler(command, cancellationToken)
                    .ConfigureAwait(false);
                string message = NormalizeResponse(response.Message);
                await _client.SendAsync(
                    configuration.BotToken,
                    configuration.ChatId,
                    message,
                    cancellationToken).ConfigureAwait(false);
            }
        }
        finally
        {
            _pollGate.Release();
        }
    }

    public async Task SendAsync(string message, CancellationToken cancellationToken = default)
    {
        TelegramBridgeConfiguration configuration = _configurationProvider();
        if (!configuration.IsConfigured)
        {
            return;
        }

        await _client.SendAsync(
            configuration.BotToken,
            configuration.ChatId,
            NormalizeResponse(message),
            cancellationToken).ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        try { _cancellation?.Cancel(); } catch { /* best effort */ }
        if (_loop is not null)
        {
            try { await _loop.ConfigureAwait(false); } catch { /* best effort */ }
        }

        _cancellation?.Dispose();
        _pollGate.Dispose();
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            TelegramBridgeConfiguration configuration = _configurationProvider();
            try
            {
                await PollOnceAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception error)
            {
                _errorSink?.Invoke(error);
            }

            TimeSpan delay = ClampPollInterval(configuration.PollInterval);
            try
            {
                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
        }
    }

    private static TimeSpan ClampPollInterval(TimeSpan value)
    {
        if (value < MinimumPollInterval)
        {
            return MinimumPollInterval;
        }

        return value > MaximumPollInterval ? MaximumPollInterval : value;
    }

    private static string NormalizeResponse(string value)
    {
        string message = (value ?? string.Empty).Trim();
        if (message.Length == 0)
        {
            return "OpenBurnBar completed the command without a response message.";
        }

        return message.Length <= TelegramBotClient.MaximumMessageCharacters
            ? message
            : message[..TelegramBotClient.MaximumMessageCharacters];
    }
}
