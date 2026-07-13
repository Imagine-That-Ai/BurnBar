using OpenBurnBar.App.ManagedAgentRuntime.Gateway;
using OpenBurnBar.App.Settings.ViewModels;
using Xunit;

namespace OpenBurnBar.App.Settings.ViewModels.Tests;

public sealed class GatewayRouteSettingsViewModelTests
{
    [Fact]
    public void Upsert_PersistsProtectedCredentialWithoutProjectingItIntoRows()
    {
        var store = new InMemoryGatewayRouteSettingsStore();
        var viewModel = new GatewayRouteSettingsViewModel(store);

        GatewayRouteMutationResult result = viewModel.Upsert(Input(credential: "secret-canary"));

        Assert.True(result.Succeeded);
        GatewayRouteSettingsRow row = Assert.Single(viewModel.Routes);
        Assert.True(row.CredentialConfigured);
        Assert.True(row.IsReady);
        Assert.Equal("secret-canary", store.ReadCredential(row.Id));
        Assert.DoesNotContain("secret-canary", row.ToString(), StringComparison.Ordinal);
        Assert.DoesNotContain("secret-canary", row.Configuration.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void Upsert_EnabledBearerWithoutCredentialFailsClosed()
    {
        var viewModel = new GatewayRouteSettingsViewModel();

        GatewayRouteMutationResult result = viewModel.Upsert(Input(credential: string.Empty));

        Assert.False(result.Succeeded);
        Assert.Contains("credential is required", result.Error, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(viewModel.Routes);
    }

    [Fact]
    public void DisabledBearerCanBePreparedButNotEnabledWithoutCredential()
    {
        var viewModel = new GatewayRouteSettingsViewModel();
        GatewayRouteInput input = Input(credential: string.Empty) with { Enabled = false };

        GatewayRouteMutationResult saved = viewModel.Upsert(input);
        GatewayRouteSettingsRow row = Assert.Single(viewModel.Routes);
        GatewayRouteMutationResult enabled = viewModel.SetEnabled(row.Id, true);

        Assert.True(saved.Succeeded);
        Assert.False(row.IsReady);
        Assert.Equal("Disabled", row.Status);
        Assert.False(enabled.Succeeded);
        Assert.False(Assert.Single(viewModel.Routes).Enabled);
    }

    [Fact]
    public void EditWithBlankCredentialPreservesExistingSecret()
    {
        var store = new InMemoryGatewayRouteSettingsStore();
        var viewModel = new GatewayRouteSettingsViewModel(store);
        GatewayRouteMutationResult created = viewModel.Upsert(Input(credential: "original-secret"));
        GatewayRouteSettingsRow original = Assert.Single(viewModel.Routes);

        GatewayRouteMutationResult updated = viewModel.Upsert(Input(credential: string.Empty) with
        {
            Id = created.RouteId,
            Model = "gpt-5.4-mini",
        });

        Assert.True(updated.Succeeded);
        GatewayRouteSettingsRow row = Assert.Single(viewModel.Routes);
        Assert.Equal("gpt-5.4-mini", row.Model);
        Assert.Equal("original-secret", store.ReadCredential(original.Id));
        Assert.True(row.CredentialConfigured);
    }

    [Fact]
    public void SwitchingToNoAuthenticationDeletesProtectedCredential()
    {
        var store = new InMemoryGatewayRouteSettingsStore();
        var viewModel = new GatewayRouteSettingsViewModel(store);
        GatewayRouteMutationResult created = viewModel.Upsert(Input(credential: "remove-me"));

        GatewayRouteMutationResult updated = viewModel.Upsert(Input(credential: string.Empty) with
        {
            Id = created.RouteId,
            Endpoint = "http://localhost:11434/v1/chat/completions",
            Authentication = GatewayRouteAuthentication.None,
        });

        Assert.True(updated.Succeeded);
        GatewayRouteSettingsRow row = Assert.Single(viewModel.Routes);
        Assert.Null(store.ReadCredential(row.Id));
        Assert.False(row.CredentialConfigured);
        Assert.True(row.IsReady);
    }

    [Fact]
    public void DeleteRemovesMetadataAndCredential()
    {
        var store = new InMemoryGatewayRouteSettingsStore();
        var viewModel = new GatewayRouteSettingsViewModel(store);
        GatewayRouteMutationResult created = viewModel.Upsert(Input(credential: "delete-me"));

        GatewayRouteMutationResult deleted = viewModel.Delete(created.RouteId!);

        Assert.True(deleted.Succeeded);
        Assert.Empty(viewModel.Routes);
        Assert.Null(store.ReadCredential(created.RouteId!));
    }

    [Fact]
    public void UnsafeRemoteHttpEndpointIsRejectedBeforePersistence()
    {
        var viewModel = new GatewayRouteSettingsViewModel();

        GatewayRouteMutationResult result = viewModel.Upsert(Input(credential: "secret") with
        {
            Endpoint = "http://provider.example/v1/chat/completions",
        });

        Assert.False(result.Succeeded);
        Assert.Contains("HTTPS", result.Error, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(viewModel.Routes);
    }

    [Fact]
    public void LoadOrdersRoutesByPriorityThenProviderAndModel()
    {
        var store = new InMemoryGatewayRouteSettingsStore(new[]
        {
            Configuration("route-c", "zai", "glm", 20),
            Configuration("route-b", "openai", "gpt", 10),
            Configuration("route-a", "anthropic", "claude", 10),
        });

        var viewModel = new GatewayRouteSettingsViewModel(store);

        Assert.Equal(new[] { "route-a", "route-b", "route-c" }, viewModel.Routes.Select(route => route.Id));
    }

    [Fact]
    public void LoadSurfacesDuplicateRouteIdsAsAConfigurationError()
    {
        var store = new InMemoryGatewayRouteSettingsStore(new[]
        {
            Configuration("duplicate", "openai", "gpt", 0),
            Configuration("DUPLICATE", "anthropic", "claude", 1),
        });

        var viewModel = new GatewayRouteSettingsViewModel(store);
        GatewayRouteMutationResult mutation = viewModel.Upsert(Input("new-secret"));

        Assert.Empty(viewModel.Routes);
        Assert.Contains("Duplicate provider route id", viewModel.LastError, StringComparison.Ordinal);
        Assert.False(mutation.Succeeded);
        Assert.Contains("storage error", mutation.Error, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(2, store.Load().Count);
    }

    private static GatewayRouteInput Input(string credential) => new(
        Id: null,
        Vendor: "openai",
        Model: "gpt-5.4",
        Endpoint: "https://api.openai.com/v1/chat/completions",
        Priority: 0,
        Enabled: true,
        Authentication: GatewayRouteAuthentication.Bearer,
        Credential: credential);

    private static GatewayRouteConfiguration Configuration(
        string id,
        string vendor,
        string model,
        int priority) => new(
            id,
            vendor,
            model,
            "https://provider.example/v1/chat/completions",
            priority,
            true,
            GatewayRouteAuthentication.None);
}
