using System;
using System.IO;
using System.Linq;
using System.Text;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class GatewayRouteTelemetryStoreTests
{
    private static readonly DateTimeOffset StartedAt =
        new(2026, 7, 14, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void OpenAiJsonUsageSeparatesCachedAndReasoningTokens()
    {
        GatewayTokenUsage usage = Assert.IsType<GatewayTokenUsage>(GatewayUsageParser.Parse(Success(
            "{\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":25,"
            + "\"prompt_tokens_details\":{\"cached_tokens\":40,\"cache_creation_tokens\":5},"
            + "\"completion_tokens_details\":{\"reasoning_tokens\":7}}}")));

        Assert.Equal(60, usage.InputTokens);
        Assert.Equal(25, usage.OutputTokens);
        Assert.Equal(5, usage.CacheCreationTokens);
        Assert.Equal(40, usage.CacheReadTokens);
        Assert.Equal(7, usage.ReasoningTokens);
    }

    [Fact]
    public void EventStreamUsesLastAuthoritativeUsageEvent()
    {
        const string body =
            "data: {\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":1}}\n\n"
            + "data: {\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":9}}\n\n"
            + "data: [DONE]\n";

        GatewayTokenUsage usage = Assert.IsType<GatewayTokenUsage>(GatewayUsageParser.Parse(
            Success(body, "text/event-stream")));

        Assert.Equal(12, usage.InputTokens);
        Assert.Equal(9, usage.OutputTokens);
    }

    [Fact]
    public void AnthropicMessageUsageParsesAndMalformedPayloadReturnsNull()
    {
        GatewayTokenUsage usage = Assert.IsType<GatewayTokenUsage>(GatewayUsageParser.Parse(Success(
            "{\"message\":{\"usage\":{\"input_tokens\":20,\"output_tokens\":3,"
            + "\"cache_creation_input_tokens\":4,\"cache_read_input_tokens\":6}}}")));

        Assert.Equal(14, usage.InputTokens);
        Assert.Equal(3, usage.OutputTokens);
        Assert.Equal(4, usage.CacheCreationTokens);
        Assert.Equal(6, usage.CacheReadTokens);
        Assert.Null(GatewayUsageParser.Parse(Success("not-json")));
    }

    [Fact]
    public void StorePersistsBoundedMetadataAndSkipsCorruptLines()
    {
        string directory = TemporaryDirectory();
        string path = Path.Combine(directory, "routes.jsonl");
        try
        {
            var writer = new GatewayRouteTelemetryStore(path);
            writer.Append(Entry("one", succeeded: true, usage: new GatewayTokenUsage(12, 4, 3, 2, 1)));
            writer.Append(Entry("two", succeeded: false, offsetMilliseconds: 1));
            File.AppendAllText(path, "not-json\n");

            string persisted = File.ReadAllText(path);
            Assert.DoesNotContain("messages", persisted, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("prompt", persisted, StringComparison.OrdinalIgnoreCase);

            var reader = new GatewayRouteTelemetryStore(path);
            GatewayTelemetrySnapshot snapshot = reader.Snapshot();
            Assert.Equal(2, snapshot.RetainedRequests);
            Assert.Equal(1, snapshot.Successes);
            Assert.Equal(1, snapshot.Failures);
            Assert.Equal(12, snapshot.InputTokens);
            Assert.Equal(4, snapshot.OutputTokens);
            Assert.Equal(new[] { "two", "one" }, reader.Recent(2).Select(entry => entry.Id));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void StoreRetainsLatestFiveThousandAndCapsRecentReads()
    {
        var store = new GatewayRouteTelemetryStore();
        for (int index = 0; index < GatewayRouteTelemetryStore.RetainedRecordLimit + 3; index++)
        {
            store.Append(Entry("id-" + index, offsetMilliseconds: index));
        }

        Assert.Equal(GatewayRouteTelemetryStore.RetainedRecordLimit, store.Snapshot().RetainedRequests);
        Assert.Equal(GatewayRouteTelemetryStore.MaximumRecentLimit, store.Recent(500).Count);
        Assert.Equal("id-5002", store.Recent(1)[0].Id);
    }

    [Fact]
    public void OversizedTelemetryFileFailsOpenAsEmpty()
    {
        string directory = TemporaryDirectory();
        string path = Path.Combine(directory, "routes.jsonl");
        try
        {
            using (FileStream stream = File.Create(path))
            {
                stream.SetLength(GatewayRouteTelemetryStore.MaximumFileBytes + 1L);
            }

            Assert.Equal(0, new GatewayRouteTelemetryStore(path).Snapshot().RetainedRequests);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void InvalidOrOversizedRecordsCannotEnterHistory()
    {
        var store = new GatewayRouteTelemetryStore();
        store.Append(Entry(
            "oversized",
            clientModel: new string('x', GatewayRouteConfiguration.MaximumModelLength + 1)));
        store.Append(Entry("negative", usage: new GatewayTokenUsage(-1, 0, 0, 0, 0)));
        store.Append(Entry("invalid-status", statusCode: 99));

        Assert.Empty(store.Recent());
        Assert.Equal(0, store.Snapshot().RetainedRequests);
    }

    private static ModelCompletionResult Success(
        string body,
        string contentType = "application/json") =>
        new(200, Encoding.UTF8.GetBytes(body), contentType, true);

    private static GatewayRouteLogEntry Entry(
        string id,
        bool succeeded = true,
        GatewayTokenUsage? usage = null,
        long offsetMilliseconds = 0,
        string clientModel = "client-model",
        int statusCode = 200)
    {
        DateTimeOffset started = StartedAt.AddMilliseconds(offsetMilliseconds);
        return new GatewayRouteLogEntry(
            id,
            started,
            started.AddMilliseconds(10),
            10,
            "/v1/chat/completions",
            clientModel,
            "routed-model",
            "route",
            "openai",
            "credential-slot",
            "canonical-model",
            "openai-compatible",
            "default",
            Degraded: false,
            Succeeded: succeeded,
            StatusCode: statusCode,
            Streamed: false,
            Usage: usage);
    }

    private static string TemporaryDirectory()
    {
        string path = Path.Combine(
            Path.GetTempPath(),
            "openburnbar-gateway-telemetry-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return path;
    }
}
