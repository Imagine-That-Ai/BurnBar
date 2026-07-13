using System;
using System.Collections.Generic;
using System.Net.Http;
using System.Text.Json;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

public sealed record GatewayComposition(
    ModelProxyRouter Router,
    IModelCompletionExecutor Executor,
    HttpClient HttpClient);

/// <summary>
/// Builds the app's gateway from non-secret route metadata. Provider tokens are
/// referenced by environment-variable name and are read only at composition;
/// they are never serialized into the route manifest, journal, or diagnostics.
/// </summary>
public static class GatewayCompositionFactory
{
    public const string RoutesEnvironmentVariable = "OPENBURNBAR_GATEWAY_ROUTES_JSON";

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

    public static IReadOnlyList<ModelRoute> ParseRoutes(string? json)
    {
        if (string.IsNullOrWhiteSpace(json))
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
            foreach (JsonElement item in document.RootElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object
                    || !TryString(item, "id", out string? id)
                    || !TryString(item, "vendor", out string? vendor)
                    || !TryString(item, "model", out string? model)
                    || !TryString(item, "endpoint", out string? endpointText)
                    || !Uri.TryCreate(endpointText, UriKind.Absolute, out Uri? endpoint)
                    || endpoint.Scheme is not ("http" or "https"))
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

                routes.Add(new ModelRoute(id!, vendor!, model!, priority, healthy, endpoint, token));
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
