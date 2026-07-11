using System;
using System.Security.Cryptography;
using System.Text;
using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>JSONL usage-log parsing parity for <see cref="UsageLogConsumer"/>.</summary>
public sealed class UsageLogConsumerTests
{
    private static readonly DateTimeOffset FallbackNow = new(2020, 1, 1, 0, 0, 0, TimeSpan.Zero);

    private static UsageLogConsumer NewConsumer() =>
        new(clock: new FixedClock(FallbackNow));

    [Fact]
    public void RecordedFixture_SkipsMalformedAndUnknownProviderLines()
    {
        var chunk = TestSupport.ReadFixture("usage-log-chunk.jsonl");

        var events = NewConsumer().Consume(chunk);

        Assert.Equal(3, events.Count);
        Assert.Equal(ConnectorProvider.Zai, events[0].Provider);
        Assert.Equal("glm-5", events[0].Model);
        Assert.Equal(ConnectorProvider.Ollama, events[1].Provider);
        Assert.Equal(ConnectorProvider.Minimax, events[2].Provider);
    }

    [Fact]
    public void ParsedEvents_CarryNormalizedBucketsAndTimestamp()
    {
        var events = NewConsumer().Consume(TestSupport.ReadFixture("usage-log-chunk.jsonl"));

        Assert.Equal(100, events[0].PromptTokens);
        Assert.Equal(50, events[0].CompletionTokens);
        Assert.Equal(150, events[0].TotalTokens);
        Assert.Equal(
            new DateTimeOffset(2026, 7, 6, 12, 0, 0, 500, TimeSpan.Zero),
            events[0].Timestamp);

        // The ollama line carries no timestamp → the injected clock's "now".
        Assert.Equal(200, events[1].PromptTokens);
        Assert.Equal(80, events[1].CompletionTokens);
        Assert.Equal(FallbackNow, events[1].Timestamp);
    }

    [Fact]
    public void Consume_EmptyChunk_YieldsNoEvents()
    {
        Assert.Empty(NewConsumer().Consume(string.Empty));
        Assert.Empty(NewConsumer().Consume("\n\n"));
    }

    [Fact]
    public void CostCalculator_IsApplied()
    {
        var consumer = new UsageLogConsumer(new StubCost(0.42), new FixedClock(FallbackNow));
        var events = consumer.Consume(
            "{\"request_id\":\"r\",\"provider\":\"zai\",\"model\":\"glm-5\",\"total_tokens\":10}\n");

        Assert.Equal(0.42, Assert.Single(events).Cost);
    }

    [Fact]
    public void DeterministicId_MatchesRawMd5CanonicalLayout()
    {
        const string requestId = "req-1";
        var digest = MD5.HashData(Encoding.UTF8.GetBytes(requestId));
        var hex = Convert.ToHexString(digest).ToLowerInvariant();
        var expected = Guid.ParseExact(
            $"{hex.Substring(0, 8)}-{hex.Substring(8, 4)}-{hex.Substring(12, 4)}-{hex.Substring(16, 4)}-{hex.Substring(20, 12)}",
            "D");

        Assert.Equal(expected, UsageLogConsumer.DeterministicId(requestId));
        Assert.Equal(UsageLogConsumer.DeterministicId(requestId), UsageLogConsumer.DeterministicId(requestId));
        Assert.NotEqual(UsageLogConsumer.DeterministicId("req-1"), UsageLogConsumer.DeterministicId("req-2"));
    }

    private sealed class StubCost : IUsageCostCalculator
    {
        private readonly double _cost;

        internal StubCost(double cost) => _cost = cost;

        public double Cost(string model, NormalizedUsageEvent usage) => _cost;
    }
}
