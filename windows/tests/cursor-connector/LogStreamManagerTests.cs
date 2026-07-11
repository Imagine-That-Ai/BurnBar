using OpenBurnBar.App.CursorConnector;
using Xunit;

namespace OpenBurnBar.App.CursorConnector.Tests;

/// <summary>Delta-tail parity for <see cref="CursorConnectorLogStreamManager"/>.</summary>
public sealed class LogStreamManagerTests
{
    private const string UsagePath = "usage.jsonl";
    private const string RoutePath = "proxy.log";

    [Fact]
    public void ReadUsageDelta_ReturnsOnlyNewlyAppendedBytes()
    {
        var source = new InMemoryLogStreamSource();
        var manager = new CursorConnectorLogStreamManager(source);

        source.Append(UsagePath, "hello");
        Assert.Equal("hello", manager.ReadUsageDelta(UsagePath));

        // No new bytes → null.
        Assert.Null(manager.ReadUsageDelta(UsagePath));

        source.Append(UsagePath, "world");
        Assert.Equal("world", manager.ReadUsageDelta(UsagePath));
    }

    [Fact]
    public void ReadUsageDelta_ResetsOnTruncation()
    {
        var source = new InMemoryLogStreamSource();
        var manager = new CursorConnectorLogStreamManager(source);

        source.Append(UsagePath, "first-long-chunk");
        Assert.Equal("first-long-chunk", manager.ReadUsageDelta(UsagePath));

        // The file shrank underneath us (rotation): re-read from the top.
        source.Replace(UsagePath, "hi");
        Assert.Equal("hi", manager.ReadUsageDelta(UsagePath));
    }

    [Fact]
    public void MissingFile_ReturnsNull()
    {
        var manager = new CursorConnectorLogStreamManager(new InMemoryLogStreamSource());
        Assert.Null(manager.ReadUsageDelta("nope.jsonl"));
    }

    [Fact]
    public void UsageAndRouteOffsets_AreIndependent()
    {
        var source = new InMemoryLogStreamSource();
        var manager = new CursorConnectorLogStreamManager(source);

        source.Append(UsagePath, "usage-1");
        source.Append(RoutePath, "route-1");

        Assert.Equal("usage-1", manager.ReadUsageDelta(UsagePath));
        Assert.Equal("route-1", manager.ReadRouteDelta(RoutePath));
        Assert.Null(manager.ReadUsageDelta(UsagePath));
        Assert.Null(manager.ReadRouteDelta(RoutePath));
    }

    [Fact]
    public void ResetOffsets_RereadsFromStart()
    {
        var source = new InMemoryLogStreamSource();
        var manager = new CursorConnectorLogStreamManager(source);

        source.Append(UsagePath, "payload");
        Assert.Equal("payload", manager.ReadUsageDelta(UsagePath));

        manager.ResetOffsets();
        Assert.Equal("payload", manager.ReadUsageDelta(UsagePath));
    }

    [Fact]
    public void RecordedFixture_TailsWholeChunkThenNull()
    {
        var fixture = TestSupport.ReadFixture("usage-log-chunk.jsonl");
        var source = new InMemoryLogStreamSource();
        var manager = new CursorConnectorLogStreamManager(source);

        source.Replace(UsagePath, fixture);
        Assert.Equal(fixture, manager.ReadUsageDelta(UsagePath));
        Assert.Null(manager.ReadUsageDelta(UsagePath));
    }
}
