using System;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class ModelCompletionExecutorTests
{
    [Fact]
    public async Task ExecuteAsync_RejectsOversizedProviderResponse()
    {
        using var client = new HttpClient(new FixedResponseHandler(
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(new byte[HttpModelCompletionExecutor.MaxResponseBytes + 1]),
            }));
        var executor = new HttpModelCompletionExecutor(client);

        ModelCompletionResult result = await executor.ExecuteAsync(
            new ModelRoute("route", "openai", "model", 0, true, new Uri("https://provider.test/v1/chat/completions")),
            new byte[] { (byte)'{' },
            CancellationToken.None);

        Assert.False(result.Succeeded);
        Assert.Equal(502, result.StatusCode);
        Assert.Empty(result.Body);
    }

    private sealed class FixedResponseHandler : HttpMessageHandler
    {
        private readonly HttpResponseMessage _response;

        public FixedResponseHandler(HttpResponseMessage response) => _response = response;

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => Task.FromResult(_response);
    }
}
