using System;
using System.Net;
using System.Text.Json.Serialization;

namespace OpenBurnBar.App.ManagedAgentRuntime.Gateway;

/// <summary>Credential behavior for one configured upstream model route.</summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum GatewayRouteAuthentication
{
    None,
    Bearer,
}

/// <summary>
/// Durable, non-secret metadata for one upstream model route. Credentials are
/// resolved separately from protected storage by route id.
/// </summary>
public sealed record GatewayRouteConfiguration(
    string Id,
    string Vendor,
    string Model,
    string Endpoint,
    int Priority,
    bool Enabled,
    GatewayRouteAuthentication Authentication,
    ModelRouteRoutingMetadata? Routing = null)
{
    public const int MaximumIdLength = 128;
    public const int MaximumVendorLength = 128;
    public const int MaximumModelLength = 256;
    public const int MaximumEndpointLength = 2048;
    public const int MaximumPriority = 10_000;
    public const int MaximumCredentialLength = 16 * 1024;

    /// <summary>Validate metadata and resolve it into the runtime-only route.</summary>
    public ModelRoute Resolve(string? protectedCredential)
    {
        Uri endpoint = Validate();
        if (protectedCredential?.Length > MaximumCredentialLength)
        {
            throw new ArgumentException(
                $"Route credential exceeds {MaximumCredentialLength} characters.",
                nameof(protectedCredential));
        }

        bool credentialReady = Authentication == GatewayRouteAuthentication.None
            || !string.IsNullOrWhiteSpace(protectedCredential);
        string? bearerToken = Authentication == GatewayRouteAuthentication.Bearer
            ? protectedCredential?.Trim()
            : null;

        return new ModelRoute(
            Id.Trim(),
            Vendor.Trim(),
            Model.Trim(),
            Priority,
            Enabled && credentialReady,
            endpoint,
            bearerToken,
            Routing);
    }

    /// <summary>Returns the validated upstream endpoint.</summary>
    public Uri Validate()
    {
        ValidateRequired(Id, nameof(Id), MaximumIdLength);
        ValidateRequired(Vendor, nameof(Vendor), MaximumVendorLength);
        ValidateRequired(Model, nameof(Model), MaximumModelLength);
        ValidateRequired(Endpoint, nameof(Endpoint), MaximumEndpointLength);
        if (Priority is < 0 or > MaximumPriority)
        {
            throw new ArgumentOutOfRangeException(
                nameof(Priority),
                $"Route priority must be between 0 and {MaximumPriority}.");
        }

        Routing?.Validate();

        if (!Uri.TryCreate(Endpoint.Trim(), UriKind.Absolute, out Uri? endpoint)
            || !(IsEndpointAllowed(endpoint) || IsCliEndpointAllowed(endpoint, Vendor)))
        {
            throw new ArgumentException(
                "Route endpoint must be HTTPS, HTTP on loopback, or a matching cli://factory endpoint, without credentials or a fragment.",
                nameof(Endpoint));
        }

        return endpoint;
    }

    /// <summary>Whether an endpoint is safe for the production HTTP executor.</summary>
    public static bool IsEndpointAllowed(Uri endpoint)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        bool isHttp = string.Equals(endpoint.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase);
        bool isHttps = string.Equals(endpoint.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase);
        return endpoint.IsAbsoluteUri
            && (isHttp || isHttps)
            && !string.IsNullOrWhiteSpace(endpoint.Host)
            && string.IsNullOrEmpty(endpoint.UserInfo)
            && string.IsNullOrEmpty(endpoint.Fragment)
            && (isHttps || IsLoopback(endpoint.Host));
    }

    public static bool IsCliEndpointAllowed(Uri endpoint, string vendor)
    {
        ArgumentNullException.ThrowIfNull(endpoint);
        string normalizedVendor = vendor?.Trim().ToLowerInvariant() ?? string.Empty;
        string expectedHost = normalizedVendor switch
        {
            "factory" or "factory-droid" => "factory",
            _ => string.Empty,
        };
        string path = endpoint.AbsolutePath.Trim('/');
        return expectedHost.Length > 0
            && endpoint.IsAbsoluteUri
            && string.Equals(endpoint.Scheme, "cli", StringComparison.OrdinalIgnoreCase)
            && string.Equals(endpoint.Host, expectedHost, StringComparison.OrdinalIgnoreCase)
            && string.IsNullOrEmpty(path)
            && string.IsNullOrEmpty(endpoint.UserInfo)
            && string.IsNullOrEmpty(endpoint.Fragment)
            && endpoint.Query.Length == 0;
    }

    private static bool IsLoopback(string host)
    {
        string normalized = host.Trim().TrimEnd('.');
        if (string.Equals(normalized, "localhost", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return IPAddress.TryParse(normalized, out IPAddress? address)
            && IPAddress.IsLoopback(address);
    }

    private static void ValidateRequired(string value, string name, int maximumLength)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException($"Route {name.ToLowerInvariant()} is required.", name);
        }

        if (value.Trim().Length > maximumLength)
        {
            throw new ArgumentException(
                $"Route {name.ToLowerInvariant()} exceeds {maximumLength} characters.",
                name);
        }
    }
}
