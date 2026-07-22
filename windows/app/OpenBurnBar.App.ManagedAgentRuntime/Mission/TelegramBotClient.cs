using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.ManagedAgentRuntime.Mission;

public readonly record struct TelegramInboundMessage(long UpdateId, string ChatId, string Text);

public sealed class TelegramBotException : Exception
{
    public TelegramBotException(string message) : base(message) { }
}

public interface ITelegramBotClient
{
    Task SendAsync(
        string botToken,
        string chatId,
        string text,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<TelegramInboundMessage>> FetchUpdatesAsync(
        string botToken,
        long? offset,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Bounded Telegram Bot API transport for Mission Control notifications and
/// commands. The bot token remains confined to the fixed Telegram request URI.
/// </summary>
public sealed class TelegramBotClient : ITelegramBotClient, IDisposable
{
    public const int MaximumMessageCharacters = 4096;
    public const int MaximumResponseBytes = 1024 * 1024;
    public const int MaximumUpdatesPerPoll = 100;

    private readonly HttpClient _httpClient;
    private readonly bool _ownsHttpClient;

    public TelegramBotClient()
        : this(new HttpClient(new SocketsHttpHandler { AllowAutoRedirect = false }), ownsHttpClient: true)
    {
    }

    public TelegramBotClient(HttpClient httpClient, bool ownsHttpClient = false)
    {
        _httpClient = httpClient ?? throw new ArgumentNullException(nameof(httpClient));
        _ownsHttpClient = ownsHttpClient;
    }

    public async Task SendAsync(
        string botToken,
        string chatId,
        string text,
        CancellationToken cancellationToken = default)
    {
        string token = ValidateBotToken(botToken);
        string destination = ValidateChatId(chatId);
        string message = ValidateMessage(text);
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint(token, "sendMessage"))
        {
            Content = new ByteArrayContent(JsonSerializer.SerializeToUtf8Bytes(new
            {
                chat_id = destination,
                text = message,
                disable_web_page_preview = true,
            })),
        };
        request.Content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("application/json");

        byte[] body = await SendBoundedAsync(request, cancellationToken).ConfigureAwait(false);
        using JsonDocument document = ParseEnvelope(body);
        EnsureSuccessfulEnvelope(document.RootElement);
    }

    public async Task<IReadOnlyList<TelegramInboundMessage>> FetchUpdatesAsync(
        string botToken,
        long? offset,
        CancellationToken cancellationToken = default)
    {
        string token = ValidateBotToken(botToken);
        var query = new StringBuilder("?timeout=1&limit=")
            .Append(MaximumUpdatesPerPoll);
        if (offset.HasValue)
        {
            query.Append("&offset=").Append(offset.Value);
        }

        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            new Uri(Endpoint(token, "getUpdates"), query.ToString()));
        byte[] body = await SendBoundedAsync(request, cancellationToken).ConfigureAwait(false);
        using JsonDocument document = ParseEnvelope(body);
        JsonElement root = document.RootElement;
        EnsureSuccessfulEnvelope(root);
        if (!root.TryGetProperty("result", out JsonElement result)
            || result.ValueKind != JsonValueKind.Array)
        {
            throw new TelegramBotException("Telegram returned an invalid updates response.");
        }

        var updates = new List<TelegramInboundMessage>();
        int inspected = 0;
        foreach (JsonElement update in result.EnumerateArray())
        {
            inspected++;
            if (inspected > MaximumUpdatesPerPoll)
            {
                throw new TelegramBotException("Telegram returned too many updates in one response.");
            }

            if (!TryDecodeInboundMessage(update, out TelegramInboundMessage inbound))
            {
                continue;
            }

            updates.Add(inbound);
        }

        return updates;
    }

    public void Dispose()
    {
        if (_ownsHttpClient)
        {
            _httpClient.Dispose();
        }
    }

    private async Task<byte[]> SendBoundedAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        HttpResponseMessage response;
        try
        {
            response = await _httpClient
                .SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error) when (error is HttpRequestException or IOException)
        {
            throw new TelegramBotException("Telegram could not be reached.");
        }

        using (response)
        {
            if ((int)response.StatusCode is < 200 or >= 300)
            {
                throw new TelegramBotException(
                    $"Telegram request failed with HTTP {(int)response.StatusCode}.");
            }

            if (response.Content.Headers.ContentLength is long contentLength
                && contentLength > MaximumResponseBytes)
            {
                throw new TelegramBotException("Telegram response exceeded the configured size limit.");
            }

            await using Stream stream = await response.Content
                .ReadAsStreamAsync(cancellationToken)
                .ConfigureAwait(false);
            using var output = new MemoryStream();
            byte[] buffer = new byte[16 * 1024];
            while (true)
            {
                int read = await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                if (read == 0)
                {
                    break;
                }

                if (output.Length + read > MaximumResponseBytes)
                {
                    throw new TelegramBotException("Telegram response exceeded the configured size limit.");
                }

                output.Write(buffer, 0, read);
            }

            return output.ToArray();
        }
    }

    private static JsonDocument ParseEnvelope(byte[] body)
    {
        try
        {
            JsonDocument document = JsonDocument.Parse(body);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                document.Dispose();
                throw new TelegramBotException("Telegram returned an invalid response.");
            }

            return document;
        }
        catch (JsonException)
        {
            throw new TelegramBotException("Telegram returned malformed JSON.");
        }
    }

    private static void EnsureSuccessfulEnvelope(JsonElement root)
    {
        if (!root.TryGetProperty("ok", out JsonElement ok)
            || ok.ValueKind != JsonValueKind.True)
        {
            throw new TelegramBotException("Telegram rejected the bot request.");
        }
    }

    private static bool TryDecodeInboundMessage(
        JsonElement update,
        out TelegramInboundMessage inbound)
    {
        inbound = default;
        if (update.ValueKind != JsonValueKind.Object
            || !update.TryGetProperty("update_id", out JsonElement updateId)
            || !updateId.TryGetInt64(out long id)
            || !update.TryGetProperty("message", out JsonElement message)
            || message.ValueKind != JsonValueKind.Object
            || !message.TryGetProperty("text", out JsonElement textElement)
            || textElement.ValueKind != JsonValueKind.String
            || !message.TryGetProperty("chat", out JsonElement chat)
            || chat.ValueKind != JsonValueKind.Object
            || !chat.TryGetProperty("id", out JsonElement chatIdElement)
            || !chatIdElement.TryGetInt64(out long chatId))
        {
            return false;
        }

        string text = (textElement.GetString() ?? string.Empty).Trim();
        if (text.Length is 0 or > MaximumMessageCharacters)
        {
            return false;
        }

        inbound = new TelegramInboundMessage(id, chatId.ToString(System.Globalization.CultureInfo.InvariantCulture), text);
        return true;
    }

    private static Uri Endpoint(string botToken, string method) =>
        new($"https://api.telegram.org/bot{botToken}/{method}", UriKind.Absolute);

    private static string ValidateBotToken(string botToken)
    {
        string token = (botToken ?? string.Empty).Trim();
        if (token.Length is < 3 or > 256 || !ContainsOnlyTokenCharacters(token))
        {
            throw new ArgumentException("The Telegram bot token is invalid.", nameof(botToken));
        }

        return token;
    }

    private static bool ContainsOnlyTokenCharacters(string token)
    {
        foreach (char character in token)
        {
            if (!(char.IsAsciiLetterOrDigit(character) || character is ':' or '_' or '-'))
            {
                return false;
            }
        }

        return true;
    }

    private static string ValidateChatId(string chatId)
    {
        string value = (chatId ?? string.Empty).Trim();
        if (value.Length is 0 or > 128)
        {
            throw new ArgumentException("The Telegram chat ID is invalid.", nameof(chatId));
        }

        return value;
    }

    private static string ValidateMessage(string text)
    {
        string value = (text ?? string.Empty).Trim();
        if (value.Length is 0 or > MaximumMessageCharacters)
        {
            throw new ArgumentException(
                $"Telegram message text must contain 1 to {MaximumMessageCharacters} characters.",
                nameof(text));
        }

        return value;
    }
}
