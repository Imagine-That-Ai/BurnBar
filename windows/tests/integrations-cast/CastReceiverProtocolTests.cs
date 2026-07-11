using System.Text.Json;
using System.Text.Json.Nodes;
using OpenBurnBar.Integrations.Cast.Protocol;
using Xunit;

namespace OpenBurnBar.Integrations.Cast.Tests;

public sealed class CastReceiverProtocolTests
{
    [Fact]
    public void Constants_MatchTheCastVocabulary()
    {
        Assert.Equal("84912283", CastReceiverProtocol.DashCastAppId);
        Assert.Equal("urn:x-cast:com.google.cast.tp.connection", CastReceiverProtocol.NamespaceConnection);
        Assert.Equal("urn:x-cast:com.google.cast.tp.heartbeat", CastReceiverProtocol.NamespaceHeartbeat);
        Assert.Equal("urn:x-cast:com.google.cast.receiver", CastReceiverProtocol.NamespaceReceiver);
        Assert.Equal("urn:x-cast:com.madmod.dashcast", CastReceiverProtocol.NamespaceDashCast);
    }

    [Fact]
    public void Connect_TargetsTheGivenDestinationWithUserAgent()
    {
        var message = CastReceiverProtocol.Connect("transport-9");
        Assert.Equal(CastReceiverProtocol.NamespaceConnection, message.Namespace);
        Assert.Equal("transport-9", message.DestinationId);

        using var doc = JsonDocument.Parse(message.PayloadUtf8);
        Assert.Equal("CONNECT", doc.RootElement.GetProperty("type").GetString());
        Assert.Equal("OpenBurnBar/1.0", doc.RootElement.GetProperty("userAgent").GetString());
    }

    [Fact]
    public void GetStatusAndLaunch_CarryTheRequestId()
    {
        using var status = JsonDocument.Parse(CastReceiverProtocol.GetStatus(11).PayloadUtf8);
        Assert.Equal("GET_STATUS", status.RootElement.GetProperty("type").GetString());
        Assert.Equal(11, status.RootElement.GetProperty("requestId").GetInt32());

        using var launch = JsonDocument.Parse(CastReceiverProtocol.LaunchDashCast(12).PayloadUtf8);
        Assert.Equal("LAUNCH", launch.RootElement.GetProperty("type").GetString());
        Assert.Equal("84912283", launch.RootElement.GetProperty("appId").GetString());
        Assert.Equal(12, launch.RootElement.GetProperty("requestId").GetInt32());
    }

    [Fact]
    public void Stop_IncludesSessionId()
    {
        using var doc = JsonDocument.Parse(CastReceiverProtocol.Stop("sess-1", 3).PayloadUtf8);
        Assert.Equal("STOP", doc.RootElement.GetProperty("type").GetString());
        Assert.Equal("sess-1", doc.RootElement.GetProperty("sessionId").GetString());
    }

    [Fact]
    public void PingAndPong_AreHeartbeatMessages()
    {
        Assert.Equal(CastReceiverProtocol.NamespaceHeartbeat, CastReceiverProtocol.Ping().Namespace);
        using var ping = JsonDocument.Parse(CastReceiverProtocol.Ping().PayloadUtf8);
        Assert.Equal("PING", ping.RootElement.GetProperty("type").GetString());
        using var pong = JsonDocument.Parse(CastReceiverProtocol.Pong().PayloadUtf8);
        Assert.Equal("PONG", pong.RootElement.GetProperty("type").GetString());
    }

    [Fact]
    public void DashCastLoad_NonForcedWithReloadSetsReloadFields()
    {
        var payload = CastReceiverProtocol.DashCastLoadPayload(
            "https://x.test/", sessionId: "sess", reloadSeconds: 60, force: false);

        Assert.Equal("https://x.test/", (string?)payload["url"]);
        Assert.False((bool)payload["force"]!);
        Assert.True((bool)payload["reload"]!);
        Assert.Equal(60_000d, (double)payload["reload_time"]!);
        Assert.Equal("sess", (string?)payload["sessionId"]);
    }

    [Fact]
    public void DashCastLoad_ForcedSuppressesReloadEvenWithReloadSeconds()
    {
        // force:true opens the URL directly; reload/reload_time must be off, or a
        // Nest Hub can stick on the DashCast splash.
        var payload = CastReceiverProtocol.DashCastLoadPayload(
            "https://x.test/", sessionId: null, reloadSeconds: 60, force: true);

        Assert.True((bool)payload["force"]!);
        Assert.False((bool)payload["reload"]!);
        Assert.Equal(0d, (double)payload["reload_time"]!);
        Assert.False(payload.ContainsKey("sessionId")); // empty session omitted
    }

    [Fact]
    public void DashCastLoad_ZeroReloadSecondsDisablesReload()
    {
        var payload = CastReceiverProtocol.DashCastLoadPayload(
            "https://x.test/", sessionId: null, reloadSeconds: 0, force: false);
        Assert.False((bool)payload["reload"]!);
        Assert.Equal(0d, (double)payload["reload_time"]!);
    }

    [Fact]
    public void TrySerialize_RejectsNonFiniteNumbersFailingClosed()
    {
        var payload = new JsonObject { ["bad"] = double.NaN };
        Assert.Null(CastReceiverProtocol.TrySerialize(payload));

        var infinity = new JsonObject { ["bad"] = double.PositiveInfinity };
        Assert.Null(CastReceiverProtocol.TrySerialize(infinity));
    }

    [Fact]
    public void TrySerialize_SucceedsForFiniteValues()
    {
        var payload = new JsonObject { ["ok"] = 3.5, ["type"] = "X" };
        var json = CastReceiverProtocol.TrySerialize(payload);
        Assert.NotNull(json);
        using var doc = JsonDocument.Parse(json!);
        Assert.Equal("X", doc.RootElement.GetProperty("type").GetString());
    }
}
