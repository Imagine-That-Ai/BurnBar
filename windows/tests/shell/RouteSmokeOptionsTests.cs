using System;
using System.IO;
using OpenBurnBar.App.Shell;
using Xunit;

namespace OpenBurnBar.App.Shell.Tests;

public sealed class RouteSmokeOptionsTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public void Parse_returns_null_when_arguments_empty(string? arguments)
    {
        Assert.Null(RouteSmokeOptions.Parse(arguments));
    }

    [Fact]
    public void Parse_returns_null_when_route_smoke_flag_has_no_following_token()
    {
        Assert.Null(RouteSmokeOptions.Parse("--route-smoke"));
    }

    [Fact]
    public void Parse_returns_null_when_route_value_is_whitespace()
    {
        Assert.Null(RouteSmokeOptions.Parse("--route-smoke \"   \""));
    }

    [Fact]
    public void Parse_accepts_route_output_and_timeout()
    {
        string output = Path.Combine(Path.GetTempPath(), "obb-smoke-" + Guid.NewGuid().ToString("N"));
        string args = $"--route-smoke dashboard --route-smoke-out \"{output}\" --route-smoke-timeout-ms 12000 --route-smoke-hold-ms 3500";

        RouteSmokeOptions? parsed = RouteSmokeOptions.Parse(args);

        Assert.NotNull(parsed);
        Assert.Equal("dashboard", parsed!.RouteKey);
        Assert.Equal(output, parsed.OutputDirectory);
        Assert.Equal(12000, parsed.TimeoutMilliseconds);
        Assert.Equal(3500, parsed.HoldMilliseconds);
    }

    [Fact]
    public void Parse_accepts_full_process_command_line()
    {
        string output = Path.Combine(Path.GetTempPath(), "obb-smoke-" + Guid.NewGuid().ToString("N"));
        string args = $"\"C:\\Program Files\\OpenBurnBar\\OpenBurnBar.App.exe\" --route-smoke dashboard --route-smoke-out \"{output}\"";

        RouteSmokeOptions? parsed = RouteSmokeOptions.Parse(args);

        Assert.NotNull(parsed);
        Assert.Equal("dashboard", parsed!.RouteKey);
        Assert.Equal(output, parsed.OutputDirectory);
    }

    [Fact]
    public void Parse_defaults_output_directory_and_timeout_when_only_route_present()
    {
        RouteSmokeOptions? parsed = RouteSmokeOptions.Parse("--route-smoke quota");

        Assert.NotNull(parsed);
        Assert.Equal("quota", parsed!.RouteKey);
        Assert.Equal(
            Path.Combine(Path.GetTempPath(), "openburnbar-route-smoke"),
            parsed.OutputDirectory);
        Assert.Equal(8000, parsed.TimeoutMilliseconds);
        Assert.Equal(0, parsed.HoldMilliseconds);
    }

    [Fact]
    public void Parse_ignores_non_positive_timeout_and_keeps_default()
    {
        RouteSmokeOptions? parsed = RouteSmokeOptions.Parse("--route-smoke chat --route-smoke-timeout-ms 0");

        Assert.NotNull(parsed);
        Assert.Equal(8000, parsed!.TimeoutMilliseconds);
    }

    [Fact]
    public void Parse_clamps_route_smoke_hold()
    {
        RouteSmokeOptions? parsed = RouteSmokeOptions.Parse("--route-smoke chat --route-smoke-hold-ms 120000");

        Assert.NotNull(parsed);
        Assert.Equal(60000, parsed!.HoldMilliseconds);
    }

    [Fact]
    public void Parse_trims_route_key()
    {
        RouteSmokeOptions? parsed = RouteSmokeOptions.Parse("--route-smoke \"  mission-control  \"");

        Assert.NotNull(parsed);
        Assert.Equal("mission-control", parsed!.RouteKey);
    }
}
