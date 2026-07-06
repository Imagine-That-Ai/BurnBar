using OpenBurnBar.App.Settings.ViewModels;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class ModelProxySettingsViewModelTests
{
    [Fact]
    public void Defaults_MatchGatewaySettings()
    {
        var vm = new ModelProxySettingsViewModel();
        Assert.False(vm.Enabled);
        Assert.Equal("127.0.0.1", vm.Host);
        Assert.Equal(8317, vm.Port);
        Assert.Equal(string.Empty, vm.AuthToken);
        Assert.False(vm.AllowUnauthenticatedLoopback);
        Assert.Equal("127.0.0.1:8317", vm.Endpoint);
        Assert.Equal("http://127.0.0.1:8317/v1", vm.EndpointUrl);
    }

    [Fact]
    public void Port_IsClampedToLegalRange()
    {
        var vm = new ModelProxySettingsViewModel();
        vm.Port = 70000;
        Assert.Equal(ModelProxySettingsViewModel.MaxPort, vm.Port);
        vm.Port = -5;
        Assert.Equal(ModelProxySettingsViewModel.MinPort, vm.Port);
        vm.Port = 9000;
        Assert.Equal(9000, vm.Port);
    }

    [Theory]
    [InlineData("127.0.0.1", true)]
    [InlineData("localhost", true)]
    [InlineData("::1", true)]
    [InlineData("0.0.0.0", false)]
    [InlineData("192.168.1.5", false)]
    public void IsLoopback_DetectsLoopbackHosts(string host, bool expected)
    {
        var vm = new ModelProxySettingsViewModel { Host = host };
        Assert.Equal(expected, vm.IsLoopback);
    }

    [Fact]
    public void AuthToken_RequiredForNonLoopback()
    {
        var vm = new ModelProxySettingsViewModel { Host = "0.0.0.0" };
        Assert.True(vm.AuthTokenRequired);
        Assert.True(vm.HasAuthTokenWarning);

        vm.AuthToken = "secret";
        Assert.False(vm.HasAuthTokenWarning);
    }

    [Fact]
    public void AuthToken_OptionalForUnauthenticatedLoopback()
    {
        var vm = new ModelProxySettingsViewModel { Host = "127.0.0.1", AllowUnauthenticatedLoopback = true };
        Assert.False(vm.AuthTokenRequired);
        Assert.False(vm.HasAuthTokenWarning);
    }

    [Fact]
    public void CopyEndpoint_WritesBaseUrlToClipboard()
    {
        var clipboard = new NullSettingsClipboard();
        var vm = new ModelProxySettingsViewModel(clipboard: clipboard) { Host = "127.0.0.1", Port = 8317 };
        vm.CopyEndpoint();
        Assert.Equal("http://127.0.0.1:8317/v1", clipboard.LastText);
        Assert.True(vm.CopiedEndpoint);
    }

    [Fact]
    public void Mutations_PersistThroughTheStoreAndReload()
    {
        var store = new InMemoryGatewayEndpointStore();
        var vm = new ModelProxySettingsViewModel(store);
        vm.Enabled = true;
        vm.Host = "0.0.0.0";
        vm.Port = 9100;
        vm.AuthToken = "tok";

        var reloaded = new ModelProxySettingsViewModel(store);
        Assert.True(reloaded.Enabled);
        Assert.Equal("0.0.0.0", reloaded.Host);
        Assert.Equal(9100, reloaded.Port);
        Assert.Equal("tok", reloaded.AuthToken);
    }

    [Fact]
    public void IsHostValid_FalseForBlankHost()
    {
        var vm = new ModelProxySettingsViewModel { Host = "   " };
        Assert.False(vm.IsHostValid);
    }
}
