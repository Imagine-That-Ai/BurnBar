using System.Collections.ObjectModel;
using OpenBurnBar.App.ManagedAgentRuntime.Gateway;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>Persistence boundary for provider-route metadata and protected credentials.</summary>
public interface IGatewayRouteSettingsStore
{
    IReadOnlyList<GatewayRouteConfiguration> Load();

    string? ReadCredential(string routeId);

    void Upsert(
        GatewayRouteConfiguration configuration,
        string? replacementCredential,
        bool replaceCredential);

    void Delete(string routeId);
}

public sealed class GatewayRouteSettingsStoreException : Exception
{
    public GatewayRouteSettingsStoreException(string message, Exception? innerException = null)
        : base(message, innerException)
    {
    }
}

/// <summary>In-memory route store for portable tests and previews.</summary>
public sealed class InMemoryGatewayRouteSettingsStore : IGatewayRouteSettingsStore
{
    private readonly List<GatewayRouteConfiguration> _routes;
    private readonly Dictionary<string, string> _credentials;

    public InMemoryGatewayRouteSettingsStore(
        IEnumerable<GatewayRouteConfiguration>? routes = null,
        IReadOnlyDictionary<string, string>? credentials = null)
    {
        _routes = routes?.ToList() ?? new List<GatewayRouteConfiguration>();
        _credentials = credentials is null
            ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, string>(credentials, StringComparer.OrdinalIgnoreCase);
    }

    public IReadOnlyList<GatewayRouteConfiguration> Load() => _routes.ToArray();

    public string? ReadCredential(string routeId) =>
        _credentials.TryGetValue(routeId, out string? credential) ? credential : null;

    public void Upsert(
        GatewayRouteConfiguration configuration,
        string? replacementCredential,
        bool replaceCredential)
    {
        int index = _routes.FindIndex(route =>
            string.Equals(route.Id, configuration.Id, StringComparison.OrdinalIgnoreCase));
        if (index >= 0)
        {
            _routes[index] = configuration;
        }
        else
        {
            _routes.Add(configuration);
        }

        if (replaceCredential)
        {
            if (string.IsNullOrWhiteSpace(replacementCredential))
            {
                _credentials.Remove(configuration.Id);
            }
            else
            {
                _credentials[configuration.Id] = replacementCredential;
            }
        }
    }

    public void Delete(string routeId)
    {
        _routes.RemoveAll(route => string.Equals(route.Id, routeId, StringComparison.OrdinalIgnoreCase));
        _credentials.Remove(routeId);
    }
}

/// <summary>Secret-free row rendered by the Model Proxy settings surface.</summary>
public sealed record GatewayRouteSettingsRow(
    GatewayRouteConfiguration Configuration,
    bool CredentialConfigured)
{
    public string Id => Configuration.Id;
    public string Vendor => Configuration.Vendor;
    public string Model => Configuration.Model;
    public string Endpoint => Configuration.Endpoint;
    public int Priority => Configuration.Priority;
    public bool Enabled => Configuration.Enabled;
    public GatewayRouteAuthentication Authentication => Configuration.Authentication;

    public bool IsReady => Enabled
        && (Authentication == GatewayRouteAuthentication.None || CredentialConfigured);

    public string Status => !Enabled
        ? "Disabled"
        : Authentication == GatewayRouteAuthentication.Bearer && !CredentialConfigured
            ? "Credential required"
            : "Route ready";
}

/// <summary>Untrusted form input for adding or editing one provider route.</summary>
public sealed record GatewayRouteInput(
    string? Id,
    string Vendor,
    string Model,
    string Endpoint,
    int Priority,
    bool Enabled,
    GatewayRouteAuthentication Authentication,
    string Credential);

public sealed record GatewayRouteMutationResult(bool Succeeded, string? RouteId, string? Error)
{
    public static GatewayRouteMutationResult Success(string routeId) => new(true, routeId, null);
    public static GatewayRouteMutationResult Failure(string error) => new(false, null, error);
}

/// <summary>
/// Manages the durable provider route catalog without projecting credentials
/// into observable state, logs, or serialized route metadata.
/// </summary>
public sealed class GatewayRouteSettingsViewModel : ObservableSettingsViewModel
{
    private readonly IGatewayRouteSettingsStore _store;
    private string? _lastError;

    public GatewayRouteSettingsViewModel(IGatewayRouteSettingsStore? store = null)
    {
        _store = store ?? new InMemoryGatewayRouteSettingsStore();
        Load();
    }

    public ObservableCollection<GatewayRouteSettingsRow> Routes { get; } = new();

    public int ConfiguredCount => Routes.Count;

    public int ReadyCount => Routes.Count(route => route.IsReady);

    public string? LastError
    {
        get => _lastError;
        private set => Set(ref _lastError, value);
    }

    public void Load()
    {
        Routes.Clear();
        try
        {
            IReadOnlyList<GatewayRouteConfiguration> configurations = _store.Load();
            if (configurations.Count > GatewayCompositionFactory.MaximumRouteCount)
            {
                throw new ArgumentException(
                    $"Provider route count exceeds {GatewayCompositionFactory.MaximumRouteCount}.");
            }
            if (configurations.Any(route => route is null))
            {
                throw new ArgumentException("Provider route metadata contains a null entry.");
            }

            var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (GatewayRouteConfiguration configuration in configurations
                         .OrderBy(route => route.Priority)
                         .ThenBy(route => route.Vendor, StringComparer.OrdinalIgnoreCase)
                         .ThenBy(route => route.Model, StringComparer.OrdinalIgnoreCase))
            {
                configuration.Validate();
                if (!ids.Add(configuration.Id.Trim()))
                {
                    throw new ArgumentException($"Duplicate provider route id '{configuration.Id.Trim()}'.");
                }

                bool credentialConfigured = configuration.Authentication == GatewayRouteAuthentication.Bearer
                    && !string.IsNullOrWhiteSpace(_store.ReadCredential(configuration.Id));
                Routes.Add(new GatewayRouteSettingsRow(configuration, credentialConfigured));
            }
            LastError = null;
        }
        catch (Exception ex) when (ex is GatewayRouteSettingsStoreException or ArgumentException)
        {
            Routes.Clear();
            LastError = "Provider routes could not be loaded: " + ex.Message;
        }

        RaiseSummary();
    }

    public GatewayRouteMutationResult Upsert(GatewayRouteInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        if (LastError is not null)
        {
            return GatewayRouteMutationResult.Failure(
                "Resolve the provider-route storage error before changing the catalog.");
        }

        GatewayRouteSettingsRow? existing = string.IsNullOrWhiteSpace(input.Id)
            ? null
            : Routes.FirstOrDefault(route =>
                string.Equals(route.Id, input.Id.Trim(), StringComparison.OrdinalIgnoreCase));
        if (!string.IsNullOrWhiteSpace(input.Id) && existing is null)
        {
            return GatewayRouteMutationResult.Failure("The route no longer exists. Refresh and try again.");
        }

        string routeId = existing?.Id ?? CreateRouteId(input.Vendor, input.Model);
        ModelRouteRoutingMetadata? routing = existing is not null
            && SameRouteIdentity(existing.Configuration, input)
                ? existing.Configuration.Routing
                : null;
        var configuration = new GatewayRouteConfiguration(
            routeId,
            input.Vendor,
            input.Model,
            input.Endpoint,
            input.Priority,
            input.Enabled,
            input.Authentication,
            routing);

        try
        {
            configuration.Validate();
        }
        catch (ArgumentException ex)
        {
            return GatewayRouteMutationResult.Failure(ex.Message);
        }

        string credential = input.Credential ?? string.Empty;
        bool replacementProvided = !string.IsNullOrWhiteSpace(credential);
        if (credential.Length > GatewayRouteConfiguration.MaximumCredentialLength)
        {
            return GatewayRouteMutationResult.Failure(
                $"Bearer credential exceeds {GatewayRouteConfiguration.MaximumCredentialLength} characters.");
        }

        bool credentialAlreadyConfigured = existing?.CredentialConfigured == true;
        if (configuration.Enabled
            && configuration.Authentication == GatewayRouteAuthentication.Bearer
            && !replacementProvided
            && !credentialAlreadyConfigured)
        {
            return GatewayRouteMutationResult.Failure(
                "A bearer credential is required before this route can be enabled.");
        }

        bool replaceCredential = replacementProvided
            || configuration.Authentication == GatewayRouteAuthentication.None;
        if (existing is null && Routes.Count == GatewayCompositionFactory.MaximumRouteCount)
        {
            return GatewayRouteMutationResult.Failure(
                $"Provider route count is limited to {GatewayCompositionFactory.MaximumRouteCount}.");
        }

        try
        {
            _store.Upsert(
                configuration,
                replacementProvided ? credential.Trim() : null,
                replaceCredential);
            Load();
            if (LastError is not null)
            {
                return GatewayRouteMutationResult.Failure(LastError);
            }
            return GatewayRouteMutationResult.Success(routeId);
        }
        catch (GatewayRouteSettingsStoreException ex)
        {
            return GatewayRouteMutationResult.Failure("The provider route could not be saved: " + ex.Message);
        }
    }

    private static bool SameRouteIdentity(
        GatewayRouteConfiguration existing,
        GatewayRouteInput input) =>
        string.Equals(existing.Vendor.Trim(), input.Vendor?.Trim(), StringComparison.OrdinalIgnoreCase)
        && string.Equals(existing.Model.Trim(), input.Model?.Trim(), StringComparison.OrdinalIgnoreCase)
        && string.Equals(existing.Endpoint.Trim(), input.Endpoint?.Trim(), StringComparison.OrdinalIgnoreCase);

    public GatewayRouteMutationResult SetEnabled(string routeId, bool enabled)
    {
        GatewayRouteSettingsRow? row = Routes.FirstOrDefault(route =>
            string.Equals(route.Id, routeId, StringComparison.OrdinalIgnoreCase));
        if (row is null)
        {
            return GatewayRouteMutationResult.Failure("The route no longer exists.");
        }

        if (enabled
            && row.Authentication == GatewayRouteAuthentication.Bearer
            && !row.CredentialConfigured)
        {
            return GatewayRouteMutationResult.Failure(
                "Add a bearer credential before enabling this route.");
        }

        try
        {
            _store.Upsert(row.Configuration with { Enabled = enabled }, null, replaceCredential: false);
            Load();
            if (LastError is not null)
            {
                return GatewayRouteMutationResult.Failure(LastError);
            }
            return GatewayRouteMutationResult.Success(row.Id);
        }
        catch (GatewayRouteSettingsStoreException ex)
        {
            return GatewayRouteMutationResult.Failure("The provider route could not be updated: " + ex.Message);
        }
    }

    public GatewayRouteMutationResult Delete(string routeId)
    {
        if (!Routes.Any(route => string.Equals(route.Id, routeId, StringComparison.OrdinalIgnoreCase)))
        {
            return GatewayRouteMutationResult.Failure("The route no longer exists.");
        }

        try
        {
            _store.Delete(routeId);
            Load();
            if (LastError is not null)
            {
                return GatewayRouteMutationResult.Failure(LastError);
            }
            return GatewayRouteMutationResult.Success(routeId);
        }
        catch (GatewayRouteSettingsStoreException ex)
        {
            return GatewayRouteMutationResult.Failure("The provider route could not be deleted: " + ex.Message);
        }
    }

    private static string CreateRouteId(string vendor, string model)
    {
        string stem = Slug(vendor) + "-" + Slug(model);
        stem = stem.Trim('-');
        if (stem.Length > 72)
        {
            stem = stem[..72].Trim('-');
        }

        if (string.IsNullOrWhiteSpace(stem))
        {
            stem = "provider-route";
        }

        return stem + "-" + Guid.NewGuid().ToString("N")[..8];
    }

    private static string Slug(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        return new string(value.Trim().ToLowerInvariant()
            .Select(character => char.IsAsciiLetterOrDigit(character) ? character : '-')
            .ToArray());
    }

    private void RaiseSummary()
    {
        OnPropertyChanged(nameof(Routes));
        OnPropertyChanged(nameof(ConfiguredCount));
        OnPropertyChanged(nameof(ReadyCount));
    }
}
