using System.Text;
using OpenBurnBar.App.ManagedAgentRuntime.Discovery;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class PiAgentRedisInstanceDecoderTests
{
    private static System.Collections.Generic.IReadOnlyList<ManagedAgentRuntime.ManagedAgentInstance> Decode(string json) =>
        PiAgentRedisInstanceDecoder.Decode(Encoding.UTF8.GetBytes(json));

    [Fact]
    public void DecodesBareArrayShape()
    {
        var result = Decode("""[{"id":"a","display_name":"Alpha"}]""");
        var instance = Assert.Single(result);
        Assert.Equal("a", instance.Id);
        Assert.Equal("Alpha", instance.DisplayName);
    }

    [Fact]
    public void DecodesWrappedInstancesShape()
    {
        var result = Decode("""{"instances":[{"id":"a"},{"id":"b"}]}""");
        Assert.Equal(2, result.Count);
        Assert.Equal("a", result[0].Id);
        Assert.Equal("b", result[1].Id);
    }

    [Theory]
    [InlineData("""[{"id":"chosen"}]""", "chosen")]
    [InlineData("""[{"instance_id":"chosen"}]""", "chosen")]
    [InlineData("""[{"instanceId":"chosen"}]""", "chosen")]
    [InlineData("""[{"name":"chosen"}]""", "chosen")]
    public void IdFallbackLadder(string json, string expected)
    {
        Assert.Equal(expected, Assert.Single(Decode(json)).Id);
    }

    [Fact]
    public void IdPrefersEarliestAlias()
    {
        // id wins over instance_id/instanceId/name when all present.
        var instance = Assert.Single(Decode("""[{"id":"first","instance_id":"second","name":"third"}]"""));
        Assert.Equal("first", instance.Id);
    }

    [Fact]
    public void EmptyOrMissingIdDropsEntry()
    {
        Assert.Empty(Decode("""[{"id":""}]"""));
        Assert.Empty(Decode("""[{"display_name":"no id here"}]"""));
    }

    [Fact]
    public void DisplayNameFallsBackThroughNameToId()
    {
        Assert.Equal("Pretty", Assert.Single(Decode("""[{"id":"x","display_name":"Pretty"}]""")).DisplayName);
        Assert.Equal("Camel", Assert.Single(Decode("""[{"id":"x","displayName":"Camel"}]""")).DisplayName);
        Assert.Equal("named", Assert.Single(Decode("""[{"id":"x","name":"named"}]""")).DisplayName);
        Assert.Equal("x", Assert.Single(Decode("""[{"id":"x"}]""")).DisplayName);
    }

    [Fact]
    public void OnlineBoolWins()
    {
        Assert.False(Assert.Single(Decode("""[{"id":"x","online":false}]""")).IsOnline);
        Assert.True(Assert.Single(Decode("""[{"id":"x","online":true}]""")).IsOnline);
    }

    [Fact]
    public void IsOnlineSnakeCaseFallback()
    {
        Assert.False(Assert.Single(Decode("""[{"id":"x","is_online":false}]""")).IsOnline);
    }

    [Theory]
    [InlineData("online", true)]
    [InlineData("running", true)]
    [InlineData("ONLINE", true)]
    [InlineData("offline", false)]
    [InlineData("stopped", false)]
    public void StatusStringDrivesOnlineWhenNoBool(string status, bool expected)
    {
        var json = $$"""[{"id":"x","status":"{{status}}"}]""";
        Assert.Equal(expected, Assert.Single(Decode(json)).IsOnline);
    }

    [Fact]
    public void DefaultsOnlineTrueWhenNothingProvided()
    {
        Assert.True(Assert.Single(Decode("""[{"id":"x"}]""")).IsOnline);
    }

    [Fact]
    public void OnlineBoolBeatsStatusString()
    {
        // The bool ladder is consulted before the status string.
        Assert.False(Assert.Single(Decode("""[{"id":"x","online":false,"status":"online"}]""")).IsOnline);
    }

    [Theory]
    [InlineData("""[{"id":"x","active_session_id":"s1"}]""", "s1")]
    [InlineData("""[{"id":"x","activeSessionId":"s2"}]""", "s2")]
    [InlineData("""[{"id":"x","session_id":"s3"}]""", "s3")]
    public void ActiveSessionIdFallbackLadder(string json, string expected)
    {
        Assert.Equal(expected, Assert.Single(Decode(json)).ActiveSessionId);
    }

    [Fact]
    public void ActiveSessionIdNullWhenAbsent()
    {
        Assert.Null(Assert.Single(Decode("""[{"id":"x"}]""")).ActiveSessionId);
    }

    [Theory]
    [InlineData("""[{"id":"x","gateway_base_url":"http://host:1/"}]""")]
    [InlineData("""[{"id":"x","gatewayBaseURL":"http://host:1/"}]""")]
    [InlineData("""[{"id":"x","base_url":"http://host:1/"}]""")]
    public void GatewayBaseUrlFallbackLadder(string json)
    {
        Assert.Equal("http://host:1/", Assert.Single(Decode(json)).GatewayBaseUrl!.ToString());
    }

    [Fact]
    public void GatewayBaseUrlFirstPresentKeyWinsEvenIfLaterKeysDiffer()
    {
        var instance = Assert.Single(Decode(
            """[{"id":"x","gateway_base_url":"http://first/","base_url":"http://second/"}]"""));
        Assert.Equal("http://first/", instance.GatewayBaseUrl!.ToString());
    }

    [Fact]
    public void GatewayBaseUrlNullWhenAbsent()
    {
        Assert.Null(Assert.Single(Decode("""[{"id":"x"}]""")).GatewayBaseUrl);
    }

    [Fact]
    public void MalformedJsonYieldsEmpty()
    {
        Assert.Empty(Decode("not json at all"));
        Assert.Empty(Decode(""));
    }

    [Fact]
    public void NonArrayNonWrappedObjectYieldsEmpty()
    {
        Assert.Empty(Decode("""{"unexpected":true}"""));
        Assert.Empty(Decode("42"));
    }

    [Fact]
    public void NonObjectArrayEntriesAreSkipped()
    {
        var result = Decode("""["string-entry", 7, {"id":"real"}]""");
        Assert.Equal("real", Assert.Single(result).Id);
    }

    [Fact]
    public void FullyPopulatedEntryRoundTrips()
    {
        var instance = Assert.Single(Decode(
            """
            [{"id":"pi-1","display_name":"Primary","online":true,
              "active_session_id":"sess-9","gateway_base_url":"http://127.0.0.1:8765/"}]
            """));
        Assert.Equal("pi-1", instance.Id);
        Assert.Equal("Primary", instance.DisplayName);
        Assert.True(instance.IsOnline);
        Assert.Equal("sess-9", instance.ActiveSessionId);
        Assert.Equal("http://127.0.0.1:8765/", instance.GatewayBaseUrl!.ToString());
    }
}
