using System.Text;
using OpenBurnBar.ComputerUse.Core.KillSwitch;
using OpenBurnBar.ComputerUse.Core.Watchdog;
using Xunit;

namespace OpenBurnBar.ComputerUse.Tests;

public sealed class WatchdogTests
{
    private sealed class FixedAuthenticator : IWatchdogPeerAuthenticator
    {
        private readonly bool _authorized;

        public FixedAuthenticator(bool authorized) => _authorized = authorized;

        public bool IsAuthorized(object peer) => _authorized;
    }

    [Fact]
    public void ActivateCommandSetsTheFlagAndReplies()
    {
        var flag = new InMemoryKillSwitchFlag();
        var server = new WatchdogServer(flag);

        var response = Encoding.UTF8.GetString(server.Handle(WatchdogCommand.Encode("activate", "panic-btn")));

        Assert.Equal("{\"ok\":true,\"detail\":\"activated\"}\n", response);
        Assert.True(flag.IsActive);
        Assert.Equal("panic-btn", flag.Reason);
    }

    [Fact]
    public void ClearCommandClearsTheFlag()
    {
        var flag = new InMemoryKillSwitchFlag();
        flag.Activate("prior");
        var server = new WatchdogServer(flag);

        var response = Encoding.UTF8.GetString(server.Handle(WatchdogCommand.Encode("clear")));

        Assert.Equal("{\"ok\":true,\"detail\":\"cleared\"}\n", response);
        Assert.False(flag.IsActive);
    }

    [Fact]
    public void HealthCommandReflectsFlagState()
    {
        var flag = new InMemoryKillSwitchFlag();
        var server = new WatchdogServer(flag);

        Assert.Equal(
            "{\"ok\":true,\"detail\":\"idle\"}\n",
            Encoding.UTF8.GetString(server.Handle(WatchdogCommand.Encode("health"))));

        flag.Activate();
        Assert.Equal(
            "{\"ok\":true,\"detail\":\"active\"}\n",
            Encoding.UTF8.GetString(server.Handle(WatchdogCommand.Encode("health"))));
    }

    [Fact]
    public void UnsupportedActionIsRejected()
    {
        var server = new WatchdogServer(new InMemoryKillSwitchFlag());
        var response = Encoding.UTF8.GetString(server.Handle(WatchdogCommand.Encode("nuke")));
        Assert.Equal("{\"ok\":false,\"detail\":\"unsupported_action\"}\n", response);
    }

    [Fact]
    public void MalformedPayloadIsRejected()
    {
        var server = new WatchdogServer(new InMemoryKillSwitchFlag());
        var response = Encoding.UTF8.GetString(server.Handle(Encoding.UTF8.GetBytes("{not json")));
        Assert.Equal("{\"ok\":false,\"detail\":\"malformed_command\"}\n", response);
    }

    [Fact]
    public void UnauthorizedPeerIsRejectedBeforeAnyCommandRuns()
    {
        var flag = new InMemoryKillSwitchFlag();
        var server = new WatchdogServer(flag);

        var response = Encoding.UTF8.GetString(
            server.HandleAuthenticated(peer: new object(), new FixedAuthenticator(false),
                WatchdogCommand.Encode("activate")));

        Assert.Equal("{\"ok\":false,\"detail\":\"peer_unauthorized\"}\n", response);
        Assert.False(flag.IsActive); // command never ran
    }

    [Fact]
    public void AuthorizedPeerRunsTheCommand()
    {
        var flag = new InMemoryKillSwitchFlag();
        var server = new WatchdogServer(flag);

        var response = Encoding.UTF8.GetString(
            server.HandleAuthenticated(peer: new object(), new FixedAuthenticator(true),
                WatchdogCommand.Encode("activate", "authed")));

        Assert.Equal("{\"ok\":true,\"detail\":\"activated\"}\n", response);
        Assert.True(flag.IsActive);
    }

    [Fact]
    public void CommandParsesActionAndReason()
    {
        var command = WatchdogCommand.Parse(WatchdogCommand.Encode("activate", "why"));
        Assert.Equal(WatchdogCommandKind.Activate, command.Kind);
        Assert.Equal("why", command.Reason);
    }

    [Fact]
    public void ResponseRoundTripUsesStructuredFields()
    {
        WatchdogResponse parsed = WatchdogResponse.Parse(
            new WatchdogResponse(ok: true, detail: "idle").Encode());

        Assert.True(parsed.Ok);
        Assert.Equal("idle", parsed.Detail);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-json")]
    [InlineData("{\"ok\":\"true\",\"detail\":\"idle\"}")]
    [InlineData("{\"ok\":true}")]
    public void MalformedResponsesFailClosed(string payload)
    {
        WatchdogResponse parsed = WatchdogResponse.Parse(Encoding.UTF8.GetBytes(payload));

        Assert.False(parsed.Ok);
        Assert.Equal("invalid_response", parsed.Detail);
    }
}
