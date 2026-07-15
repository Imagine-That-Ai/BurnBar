using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Mission;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class TelegramBotClientTests
{
    [Fact]
    public async Task SendAsync_UsesFixedTelegramEndpointAndCorrectJsonShape()
    {
        HttpRequestMessage? captured = null;
        byte[]? capturedBody = null;
        using var http = new HttpClient(new DelegateHandler(async (request, _) =>
        {
            captured = request;
            capturedBody = await request.Content!.ReadAsByteArrayAsync();
            return JsonResponse("{\"ok\":true,\"result\":{\"message_id\":1}}");
        }));
        using var client = new TelegramBotClient(http);

        await client.SendAsync("123:abc_DEF", "-456", "Build finished");

        Assert.Equal(HttpMethod.Post, captured!.Method);
        Assert.Equal(
            "https://api.telegram.org/bot123:abc_DEF/sendMessage",
            captured.RequestUri!.AbsoluteUri);
        string body = Encoding.UTF8.GetString(capturedBody!);
        Assert.Contains("\"chat_id\":\"-456\"", body, StringComparison.Ordinal);
        Assert.Contains("\"text\":\"Build finished\"", body, StringComparison.Ordinal);
        Assert.Contains("\"disable_web_page_preview\":true", body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task FetchUpdatesAsync_UsesOffsetAndDecodesOnlyBoundedTextMessages()
    {
        HttpRequestMessage? captured = null;
        using var http = new HttpClient(new DelegateHandler((request, _) =>
        {
            captured = request;
            return Task.FromResult(JsonResponse(
                "{\"ok\":true,\"result\":["
                + "{\"update_id\":9,\"message\":{\"text\":\" /status \",\"chat\":{\"id\":-42}}},"
                + "{\"update_id\":10,\"message\":{\"chat\":{\"id\":-42}}}]}"));
        }));
        using var client = new TelegramBotClient(http);

        var updates = await client.FetchUpdatesAsync("123:abc", 9);

        Assert.Contains("timeout=1", captured!.RequestUri!.Query, StringComparison.Ordinal);
        Assert.Contains("limit=100", captured.RequestUri.Query, StringComparison.Ordinal);
        Assert.Contains("offset=9", captured.RequestUri.Query, StringComparison.Ordinal);
        TelegramInboundMessage update = Assert.Single(updates);
        Assert.Equal(9, update.UpdateId);
        Assert.Equal("-42", update.ChatId);
        Assert.Equal("/status", update.Text);
    }

    [Fact]
    public async Task Failures_NeverEchoTokenOrProviderBody()
    {
        const string token = "123:super_secret";
        using var http = new HttpClient(new DelegateHandler((_, _) => Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.Unauthorized)
            {
                Content = new StringContent($"token={token}; provider detail"),
            })));
        using var client = new TelegramBotClient(http);

        TelegramBotException error = await Assert.ThrowsAsync<TelegramBotException>(() =>
            client.SendAsync(token, "1", "hello"));

        Assert.DoesNotContain(token, error.Message, StringComparison.Ordinal);
        Assert.DoesNotContain("provider detail", error.Message, StringComparison.Ordinal);
        Assert.Contains("401", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task FetchUpdatesAsync_RejectsOversizedStreamingResponse()
    {
        using var http = new HttpClient(new DelegateHandler((_, _) => Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StreamContent(new MemoryStream(
                    Enumerable.Repeat((byte)'x', TelegramBotClient.MaximumResponseBytes + 1).ToArray())),
            })));
        using var client = new TelegramBotClient(http);

        TelegramBotException error = await Assert.ThrowsAsync<TelegramBotException>(() =>
            client.FetchUpdatesAsync("123:abc", null));

        Assert.Contains("size limit", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task InvalidToken_IsRejectedBeforeNetworkDispatch()
    {
        int calls = 0;
        using var http = new HttpClient(new DelegateHandler((_, _) =>
        {
            Interlocked.Increment(ref calls);
            return Task.FromResult(JsonResponse("{\"ok\":true}"));
        }));
        using var client = new TelegramBotClient(http);

        await Assert.ThrowsAsync<ArgumentException>(() =>
            client.SendAsync("bad/token", "1", "hello"));

        Assert.Equal(0, calls);
    }

    [Fact]
    public async Task Cancellation_IsPropagated()
    {
        using var http = new HttpClient(new DelegateHandler(async (_, cancellationToken) =>
        {
            await Task.Delay(TimeSpan.FromMinutes(1), cancellationToken);
            return JsonResponse("{\"ok\":true}");
        }));
        using var client = new TelegramBotClient(http);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            client.FetchUpdatesAsync("123:abc", null, cancellation.Token));
    }

    private static HttpResponseMessage JsonResponse(string json) =>
        new(HttpStatusCode.OK)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };

    private sealed class DelegateHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> handler)
        : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => handler(request, cancellationToken);
    }
}
