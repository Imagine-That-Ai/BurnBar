using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text.Json;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

public sealed record GatewayComposition(
    ModelProxyRouter Router,
    IModelCompletionExecutor Executor,
    HttpClient HttpClient) : IDisposable
{
    public void Dispose() => HttpClient.Dispose();
}

/// <summary>
/// Builds the app's gateway from non-secret route metadata. Production callers
/// resolve credentials from protected storage; the environment parser remains
/// only as a compatibility seam for development and tests.
/// </summary>
public static class GatewayCompositionFactory
{
    public const string RoutesEnvironmentVariable = "OPENBURNBAR_GATEWAY_ROUTES_JSON";
    public const int MaximumRouteCount = 128;
    public const int MaximumRouteManifestCharacters = 1024 * 1024;

    public static GatewayComposition CreateFromEnvironment()
    {
        var client = new HttpClient();
        IReadOnlyList<ModelRoute> routes = ParseRoutes(
            Environment.GetEnvironmentVariable(RoutesEnvironmentVariable));
        return new GatewayComposition(
            new ModelProxyRouter(routes),
            new HttpModelCompletionExecutor(client),
            client);
    }

    /// <summary>
    /// Create the production gateway from durable metadata and a protected
    /// credential resolver. The resolver receives the route id only; no secret
    /// is serialized back into the configuration.
    /// </summary>
    public static GatewayComposition Create(
        IReadOnlyList<GatewayRouteConfiguration> configurations,
        Func<string, string?> protectedCredentialResolver,
        ModelRouteHealthStore? healthStore = null)
    {
        ArgumentNullException.ThrowIfNull(configurations);
        ArgumentNullException.ThrowIfNull(protectedCredentialResolver);
        if (configurations.Count > MaximumRouteCount)
        {
            throw new ArgumentException(
                $"Gateway route count exceeds {MaximumRouteCount}.",
                nameof(configurations));
        }

        var routes = new List<ModelRoute>(configurations.Count);
        var routeIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (GatewayRouteConfiguration configuration in configurations)
        {
            ArgumentNullException.ThrowIfNull(configuration);
            configuration.Validate();
            string routeId = configuration.Id.Trim();
            if (!routeIds.Add(routeId))
            {
                throw new ArgumentException($"Duplicate gateway route id '{routeId}'.", nameof(configurations));
            }

            string? credential = configuration.Authentication == GatewayRouteAuthentication.Bearer
                ? protectedCredentialResolver(routeId)
                : null;
            routes.Add(configuration.Resolve(credential));
        }

        var client = new HttpClient();
        return new GatewayComposition(
            new ModelProxyRouter(routes.Count == 0 ? DefaultRoutes() : routes, healthStore),
            new HttpModelCompletionExecutor(client),
            client);
    }

    public static IReadOnlyList<ModelRoute> ParseRoutes(string? json)
    {
        if (string.IsNullOrWhiteSpace(json) || json.Length > MaximumRouteManifestCharacters)
        {
            return DefaultRoutes();
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                return DefaultRoutes();
            }

            var routes = new List<ModelRoute>();
            int inspected = 0;
            foreach (JsonElement item in document.RootElement.EnumerateArray())
            {
                inspected++;
                if (inspected > MaximumRouteCount)
                {
                    break;
                }

                if (item.ValueKind != JsonValueKind.Object
                    || !TryString(item, "id", out string? id)
                    || !TryString(item, "vendor", out string? vendor)
                    || !TryString(item, "model", out string? model)
                    || !TryString(item, "endpoint", out string? endpointText)
                    || !Uri.TryCreate(endpointText, UriKind.Absolute, out _))
                {
                    continue;
                }

                int priority = TryInt(item, "priority", out int parsedPriority) ? parsedPriority : routes.Count;
                bool healthy = !item.TryGetProperty("healthy", out JsonElement healthyElement)
                    || healthyElement.ValueKind != JsonValueKind.False;
                string? token = null;
                if (TryString(item, "bearerTokenEnvironmentVariable", out string? tokenName)
                    && !string.IsNullOrWhiteSpace(tokenName))
                {
                    token = Environment.GetEnvironmentVariable(tokenName);
                }

                try
                {
                    var configuration = new GatewayRouteConfiguration(
                        id!,
                        vendor!,
                        model!,
                        endpointText!,
                        priority,
                        healthy,
                        tokenName is null
                            ? GatewayRouteAuthentication.None
                            : GatewayRouteAuthentication.Bearer);
                    routes.Add(configuration.Resolve(token));
                }
                catch (ArgumentException)
                {
                    // Compatibility manifests skip malformed routes and retain
                    // the fail-closed unconfigured fallback when none are valid.
                }
            }

            return routes.Count == 0 ? DefaultRoutes() : routes;
        }
        catch (JsonException)
        {
            return DefaultRoutes();
        }
    }

    private static IReadOnlyList<ModelRoute> DefaultRoutes() => new[]
    {
        new ModelRoute("openburnbar-local", "openburnbar", "openburnbar-local", 0, true),
    };

    private static bool TryString(JsonElement item, string name, out string? value)
    {
        value = null;
        if (!item.TryGetProperty(name, out JsonElement element) || element.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        value = element.GetString();
        return !string.IsNullOrWhiteSpace(value);
    }

    private static bool TryInt(JsonElement item, string name, out int value)
    {
        value = 0;
        return item.TryGetProperty(name, out JsonElement element)
            && element.TryGetInt32(out value);
    }
}
