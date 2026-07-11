using OpenBurnBar.App.Shell;
using Xunit;

namespace OpenBurnBar.App.Shell.Tests;

public sealed class WindowsActivationRouterTests
{
    [Fact]
    public void Normal_launch_keeps_tray_first()
    {
        WindowsActivationRoute? route = WindowsActivationRouter.Resolve(
            WindowsActivationRouter.FromLaunchArguments(""));

        Assert.Null(route);
    }

    [Theory]
    [InlineData("openburnbar://dashboard", "dashboard")]
    [InlineData("openburnbar://settings/updates", "settings")]
    [InlineData("openburnbar://open?route=mission-control", "missionControl")]
    [InlineData("openburnbar://analysis-models", "elderWand")]
    public void Protocol_routes_to_known_surface(string uri, string expected)
    {
        WindowsActivationRoute? route = WindowsActivationRouter.Resolve(
            WindowsActivationRouter.FromProtocolUri(uri));

        Assert.NotNull(route);
        Assert.Equal(expected, route!.RouteKey);
        Assert.True(route.OpensMainWindow);
    }

    [Theory]
    [InlineData("C:\\tmp\\thread.burnbarchat", "chat")]
    [InlineData("C:\\tmp\\pane.burnbarpane", "dashboard")]
    public void File_activation_routes_export_formats(string file, string expected)
    {
        WindowsActivationRoute? route = WindowsActivationRouter.Resolve(
            WindowsActivationRouter.FromFiles(new[] { file }));

        Assert.NotNull(route);
        Assert.Equal(expected, route!.RouteKey);
        Assert.True(route.OpensMainWindow);
    }

    [Theory]
    [InlineData("route=quota", "quota")]
    [InlineData("action=check-updates", "settings")]
    [InlineData("openburnbar://session-logs", "sessionLogs")]
    public void Toast_arguments_route_deep_links(string args, string expected)
    {
        WindowsActivationRoute? route = WindowsActivationRouter.Resolve(
            WindowsActivationRouter.FromToastArguments(args));

        Assert.NotNull(route);
        Assert.Equal(expected, route!.RouteKey);
        Assert.True(route.OpensMainWindow);
    }

    [Fact]
    public void Launch_route_flag_opens_main_window()
    {
        WindowsActivationRoute? route = WindowsActivationRouter.Resolve(
            WindowsActivationRouter.FromLaunchArguments("--openburnbar-route settings"));

        Assert.NotNull(route);
        Assert.Equal("settings", route!.RouteKey);
        Assert.True(route.OpensMainWindow);
    }
}
