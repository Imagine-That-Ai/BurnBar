using OpenBurnBar.App.ManagedAgentRuntime;
using Xunit;

namespace OpenBurnBar.App.ManagedAgentRuntime.Tests;

public sealed class PiAgentCommandProfileTests
{
    [Fact]
    public void LiveAppStatusArguments()
    {
        Assert.Equal(new[] { "agent", "status" }, PiAgentCommandProfile.Live.AppStatusArguments);
    }

    [Fact]
    public void LiveLaunchAppArguments()
    {
        Assert.Equal(new[] { "agent", "start", "--detach" }, PiAgentCommandProfile.Live.LaunchAppArguments);
    }

    [Fact]
    public void LiveStartGatewayArguments()
    {
        Assert.Equal(new[] { "gateway", "start", "--accept-hooks" }, PiAgentCommandProfile.Live.StartGatewayArguments);
    }

    [Fact]
    public void LiveInstallGatewayArguments()
    {
        Assert.Equal(
            new[] { "gateway", "install", "--force", "--accept-hooks" },
            PiAgentCommandProfile.Live.InstallGatewayArguments);
    }

    [Fact]
    public void LiveListInstancesArguments()
    {
        Assert.NotNull(PiAgentCommandProfile.Live.ListInstancesArguments);
        Assert.Equal(new[] { "agent", "list", "--json" }, PiAgentCommandProfile.Live.ListInstancesArguments!);
    }

    [Fact]
    public void EqualityIsStructuralOverArgumentVectors()
    {
        var a = new PiAgentCommandProfile(
            appStatusArguments: new[] { "agent", "status" },
            launchAppArguments: new[] { "agent", "start", "--detach" },
            startGatewayArguments: new[] { "gateway", "start", "--accept-hooks" },
            installGatewayArguments: new[] { "gateway", "install", "--force", "--accept-hooks" },
            listInstancesArguments: new[] { "agent", "list", "--json" });

        Assert.Equal(PiAgentCommandProfile.Live, a);
        Assert.Equal(PiAgentCommandProfile.Live.GetHashCode(), a.GetHashCode());
    }

    [Fact]
    public void DifferingArgumentsAreNotEqual()
    {
        var different = new PiAgentCommandProfile(
            appStatusArguments: new[] { "agent", "status", "--json" },
            launchAppArguments: new[] { "agent", "start", "--detach" },
            startGatewayArguments: new[] { "gateway", "start", "--accept-hooks" },
            installGatewayArguments: new[] { "gateway", "install", "--force", "--accept-hooks" },
            listInstancesArguments: new[] { "agent", "list", "--json" });

        Assert.NotEqual(PiAgentCommandProfile.Live, different);
    }

    [Fact]
    public void NullListInstancesIsRespected()
    {
        var profile = new PiAgentCommandProfile(
            appStatusArguments: new[] { "agent", "status" },
            launchAppArguments: new[] { "agent", "start", "--detach" },
            startGatewayArguments: new[] { "gateway", "start", "--accept-hooks" },
            installGatewayArguments: new[] { "gateway", "install", "--force", "--accept-hooks" },
            listInstancesArguments: null);

        Assert.Null(profile.ListInstancesArguments);
        Assert.NotEqual(PiAgentCommandProfile.Live, profile);
    }
}
