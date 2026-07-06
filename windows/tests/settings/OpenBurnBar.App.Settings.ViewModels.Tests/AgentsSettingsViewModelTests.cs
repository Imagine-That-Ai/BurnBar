using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.CursorConnector;
using OpenBurnBar.App.ManagedAgentRuntime;
using OpenBurnBar.App.Settings;
using OpenBurnBar.App.Settings.ViewModels.Agents;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class AgentsSettingsViewModelTests
{
    private static readonly IReadOnlyList<AgentProvider> Universe = new[]
    {
        AgentProvider.ClaudeCode, AgentProvider.Codex, AgentProvider.OpenCode,
    };

    [Fact]
    public void QuotaDisplay_DefaultsToAllVisibleInUniverseOrder()
    {
        var vm = new AgentsSettingsViewModel(Universe);
        Assert.Equal(3, vm.QuotaDisplay.VisibleCount);
        Assert.False(vm.QuotaDisplay.CumulativeAcrossAccounts);
        Assert.Equal(Universe, vm.QuotaDisplay.VisibleProviders);
    }

    [Fact]
    public void HidingProvider_DropsItFromVisibleSet()
    {
        var vm = new AgentsSettingsViewModel(Universe);
        vm.QuotaDisplay.SetProviderVisible(AgentProvider.Codex, false);
        Assert.Equal(2, vm.QuotaDisplay.VisibleCount);
        Assert.DoesNotContain(AgentProvider.Codex, vm.QuotaDisplay.VisibleProviders);
    }

    [Fact]
    public void ShowAllProviders_RestoresEveryone()
    {
        var vm = new AgentsSettingsViewModel(Universe);
        vm.QuotaDisplay.SetProviderVisible(AgentProvider.Codex, false);
        vm.QuotaDisplay.ShowAllProviders();
        Assert.Equal(3, vm.QuotaDisplay.VisibleCount);
    }

    [Fact]
    public void MoveProvider_ReordersThePopover()
    {
        var vm = new AgentsSettingsViewModel(Universe);
        vm.QuotaDisplay.MoveProvider(AgentProvider.OpenCode, up: true);
        Assert.Equal(
            new[] { AgentProvider.ClaudeCode, AgentProvider.OpenCode, AgentProvider.Codex },
            vm.QuotaDisplay.VisibleProviders);
    }

    [Fact]
    public void QuotaDisplay_PersistsThroughStore()
    {
        var store = new InMemoryQuotaDisplayStore();
        var vm = new AgentsSettingsViewModel(Universe, store);
        vm.QuotaDisplay.CumulativeAcrossAccounts = true;
        vm.QuotaDisplay.SetProviderVisible(AgentProvider.Codex, false);

        var reloaded = new AgentsSettingsViewModel(Universe, store);
        Assert.True(reloaded.QuotaDisplay.CumulativeAcrossAccounts);
        Assert.DoesNotContain(AgentProvider.Codex, reloaded.QuotaDisplay.VisibleProviders);
    }

    [Fact]
    public void Runtimes_ExposeHermesAndPiWithDefaultGateways()
    {
        var vm = new AgentsSettingsViewModel(Universe);
        var hermes = vm.Runtimes.For(ManagedAgentRuntimeKind.Hermes);
        var pi = vm.Runtimes.For(ManagedAgentRuntimeKind.PiAgent);

        Assert.Equal("http://127.0.0.1:8642/", hermes.GatewayBaseUrl);
        Assert.Equal("http://127.0.0.1:8765/", pi.GatewayBaseUrl);
        Assert.True(hermes.IsGatewayUrlValid);
    }

    [Fact]
    public void RuntimeConnection_PersistsThroughStore()
    {
        var store = new InMemoryAgentRuntimeConnectionsStore();
        var vm = new AgentsSettingsViewModel(Universe, runtimeStore: store);
        var hermes = vm.Runtimes.For(ManagedAgentRuntimeKind.Hermes);
        hermes.LaunchWithApp = true;
        hermes.BearerToken = "secret";

        var reloaded = new AgentsSettingsViewModel(Universe, runtimeStore: store);
        var reloadedHermes = reloaded.Runtimes.For(ManagedAgentRuntimeKind.Hermes);
        Assert.True(reloadedHermes.LaunchWithApp);
        Assert.Equal("secret", reloadedHermes.BearerToken);
    }

    [Fact]
    public void BadGatewayUrl_FlagsInvalid()
    {
        var vm = new AgentsSettingsViewModel(Universe);
        var hermes = vm.Runtimes.For(ManagedAgentRuntimeKind.Hermes);
        hermes.GatewayBaseUrl = "not a url";
        Assert.False(hermes.IsGatewayUrlValid);
    }

    [Fact]
    public void CursorConnector_ExposesEveryConnectorProvider()
    {
        var vm = new AgentsSettingsViewModel(Universe);
        var providers = vm.ConnectorProviders.Select(r => r.Provider).ToArray();
        Assert.Equal(ConnectorProviderRawValue.AllCases.Count, providers.Length);
    }

    [Fact]
    public void EnablingConnectorProvider_ExposesItsModels()
    {
        var store = new InMemoryCursorConnectorStore();
        var vm = new AgentsSettingsViewModel(Universe, cursorStore: store);
        var provider = ConnectorProviderRawValue.AllCases[0];

        vm.SetConnectorProviderEnabled(provider, true);
        Assert.NotEmpty(vm.CursorExposedModels);

        var reloaded = new AgentsSettingsViewModel(Universe, cursorStore: store);
        Assert.True(reloaded.ConnectorProviders.First(r => r.Provider == provider).Enabled);
    }

    [Fact]
    public void CursorPreferredPort_MatchesConnectorDefault()
    {
        var vm = new AgentsSettingsViewModel(Universe);
        Assert.Equal(8742, vm.CursorPreferredPort);
    }
}
