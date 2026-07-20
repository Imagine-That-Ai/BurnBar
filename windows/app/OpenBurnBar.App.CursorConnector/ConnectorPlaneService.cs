using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using OpenBurnBar.App.Configuration;

namespace OpenBurnBar.App.CursorConnector;

public interface IConnectorSecretStore
{
    string? Read(ConnectorKind kind);
    void Write(ConnectorKind kind, string? secret);
}

public sealed class ProtectedConnectorSecretStore : IConnectorSecretStore
{
    private const string Prefix = "connector-plane.";
    private readonly IAppSecretStore _store;

    public ProtectedConnectorSecretStore(IAppSecretStore store) =>
        _store = store ?? throw new ArgumentNullException(nameof(store));

    public string? Read(ConnectorKind kind) => _store.Read(Account(kind));

    public void Write(ConnectorKind kind, string? secret)
    {
        string? normalized = secret?.Trim();
        if (string.IsNullOrEmpty(normalized)) _store.Delete(Account(kind));
        else _store.Write(Account(kind), normalized);
    }

    private static string Account(ConnectorKind kind) => Prefix + kind.ToString().ToLowerInvariant();
}

public interface IConnectorPlaneStateStore
{
    string? Read();
    void Write(string json);
}

public sealed class FileConnectorPlaneStateStore : IConnectorPlaneStateStore
{
    private readonly string _path;
    public FileConnectorPlaneStateStore(string path) => _path = !string.IsNullOrWhiteSpace(path)
        ? path : throw new ArgumentException("Connector state path is required.", nameof(path));

    public string? Read() => File.Exists(_path) ? File.ReadAllText(_path) : null;

    public void Write(string json)
    {
        string directory = Path.GetDirectoryName(_path)
            ?? throw new InvalidOperationException("Connector state directory is unavailable.");
        Directory.CreateDirectory(directory);
        string temporary = _path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(temporary, json, new UTF8Encoding(false));
        File.Move(temporary, _path, true);
    }
}

public sealed record ConnectorTransportResponse(int StatusCode, string Body);

public interface IConnectorTransport
{
    Task<ConnectorTransportResponse> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken);
}

public sealed class PublicHttpsConnectorTransport : IConnectorTransport
{
    public const int MaximumResponseBytes = 512 * 1024;

    public async Task<ConnectorTransportResponse> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        using var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            ConnectCallback = ConnectPublicAsync,
        };
        using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
        using HttpResponseMessage response = await client.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            cancellationToken).ConfigureAwait(false);
        if ((int)response.StatusCode is >= 300 and <= 399)
        {
            throw new HttpRequestException("Connector redirects are denied; save the validated destination explicitly.");
        }
        byte[] body = await ReadBoundedAsync(response.Content, cancellationToken).ConfigureAwait(false);
        return new ConnectorTransportResponse((int)response.StatusCode, Encoding.UTF8.GetString(body));
    }

    public static bool IsPublicAddress(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any)) return false;
        byte[] bytes = address.GetAddressBytes();
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            return bytes[0] switch
            {
                0 or 10 or 127 => false,
                100 when bytes[1] is >= 64 and <= 127 => false,
                169 when bytes[1] == 254 => false,
                172 when bytes[1] is >= 16 and <= 31 => false,
                192 when bytes[1] == 168 => false,
                >= 224 => false,
                _ => true,
            };
        }
        return address.AddressFamily == AddressFamily.InterNetworkV6
            && !address.IsIPv6LinkLocal
            && !address.IsIPv6Multicast
            && !address.IsIPv6SiteLocal
            && (bytes[0] & 0xFE) != 0xFC;
    }

    private static async ValueTask<Stream> ConnectPublicAsync(
        SocketsHttpConnectionContext context,
        CancellationToken cancellationToken)
    {
        IPAddress[] addresses = await Dns.GetHostAddressesAsync(
            context.DnsEndPoint.Host,
            cancellationToken).ConfigureAwait(false);
        if (addresses.Length == 0 || addresses.Any(address => !IsPublicAddress(address)))
        {
            throw new HttpRequestException("Connector destination did not resolve exclusively to public addresses.");
        }
        IPAddress selected = addresses[0];
        var socket = new Socket(selected.AddressFamily, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            await socket.ConnectAsync(selected, context.DnsEndPoint.Port, cancellationToken).ConfigureAwait(false);
            return new NetworkStream(socket, ownsSocket: true);
        }
        catch { socket.Dispose(); throw; }
    }

    private static async Task<byte[]> ReadBoundedAsync(HttpContent content, CancellationToken cancellationToken)
    {
        if (content.Headers.ContentLength is > MaximumResponseBytes)
            throw new HttpRequestException("Connector response exceeds the safety limit.");
        await using Stream input = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = new byte[16 * 1024];
        while (true)
        {
            int read = await input.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read == 0) return output.ToArray();
            if (output.Length + read > MaximumResponseBytes)
                throw new HttpRequestException("Connector response exceeds the safety limit.");
            output.Write(buffer, 0, read);
        }
    }
}

public sealed class ConnectorPlaneService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };
    private readonly IConnectorPlaneStateStore _stateStore;
    private readonly IConnectorSecretStore _secrets;
    private readonly IConnectorTransport _transport;
    private readonly Func<string, CancellationToken, Task<IPAddress[]>> _resolver;
    private readonly IConnectorClock _clock;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private StoredConnectorPlane? _state;

    public ConnectorPlaneService(
        IConnectorPlaneStateStore stateStore,
        IConnectorSecretStore secrets,
        IConnectorTransport transport,
        Func<string, CancellationToken, Task<IPAddress[]>>? resolver = null,
        IConnectorClock? clock = null)
    {
        _stateStore = stateStore ?? throw new ArgumentNullException(nameof(stateStore));
        _secrets = secrets ?? throw new ArgumentNullException(nameof(secrets));
        _transport = transport ?? throw new ArgumentNullException(nameof(transport));
        _resolver = resolver ?? Dns.GetHostAddressesAsync;
        _clock = clock ?? SystemConnectorClock.Instance;
    }

    public async Task<ConnectorPlaneSnapshot> SnapshotAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return Snapshot(Load()); }
        finally { _gate.Release(); }
    }

    public async Task<ConnectorPlaneSnapshot> UpdateConfigAsync(
        ConnectorConfigUpdateRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        Uri url = await ValidatePublicHttpsAsync(request.Config.BaseUrl, cancellationToken).ConfigureAwait(false);
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            StoredConnectorPlane state = Load();
            state.Configs[request.Config.Kind] = new StoredConnectorConfig(
                request.Config.Kind,
                request.Config.IsEnabled,
                url.AbsoluteUri,
                request.Config.AuthKind,
                request.Config.Metadata?.ToDictionary(pair => pair.Key, pair => pair.Value.Clone(), StringComparer.Ordinal)
                    ?? new Dictionary<string, JsonElement>(StringComparer.Ordinal));
            if (request.ReplaceSecret) _secrets.Write(request.Config.Kind, request.Secret);
            state.Validations.Remove(request.Config.Kind);
            state = state with { UpdatedAt = _clock.UtcNow };
            Persist(state);
            return Snapshot(state);
        }
        finally { _gate.Release(); }
    }

    public async Task<ConnectorActionResponse> PerformActionAsync(
        ConnectorActionRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        StoredConnectorConfig config;
        string? secret;
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            StoredConnectorPlane state = Load();
            config = state.Configs[request.Kind];
            secret = _secrets.Read(request.Kind)?.Trim();
            if (!config.IsEnabled)
                return Record(state, request, false, $"{DisplayName(request.Kind)} is disabled.", "Enable the connector before testing it.", ConnectorHealthStatus.Disabled, null);
            if (string.IsNullOrEmpty(secret))
                return Record(state, request, false, $"{DisplayName(request.Kind)} is missing credentials.", "Save a credential first.", ConnectorHealthStatus.MissingSecret, null);
        }
        finally { _gate.Release(); }

        ConnectorActionResponse result;
        try
        {
            Uri baseUrl = await ValidatePublicHttpsAsync(config.BaseUrl, cancellationToken).ConfigureAwait(false);
            using HttpRequestMessage outbound = BuildRequest(config.Kind, baseUrl, secret!);
            ConnectorTransportResponse response = await _transport.SendAsync(outbound, cancellationToken).ConfigureAwait(false);
            if (response.StatusCode is < 200 or >= 300)
                throw new HttpRequestException($"Connector returned HTTP {response.StatusCode}.");
            using JsonDocument payload = JsonDocument.Parse(response.Body);
            (string summary, string? detail) = Summarize(config.Kind, payload.RootElement);
            result = new ConnectorActionResponse(config.Kind, request.Action, true, summary, detail, payload.RootElement.Clone(), _clock.UtcNow);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch (Exception error)
        {
            result = new ConnectorActionResponse(config.Kind, request.Action, false, $"{DisplayName(config.Kind)} request failed.", Bound(error.Message, 4096), null, _clock.UtcNow);
        }

        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            StoredConnectorPlane state = Load();
            return Record(state, request, result.Ok, result.Summary, result.Detail,
                result.Ok ? ConnectorHealthStatus.Healthy : ConnectorHealthStatus.Degraded, result.Payload);
        }
        finally { _gate.Release(); }
    }

    public async Task<Uri> ValidatePublicHttpsAsync(string rawUrl, CancellationToken cancellationToken = default)
    {
        if (!Uri.TryCreate(rawUrl?.Trim(), UriKind.Absolute, out Uri? url)
            || url.Scheme != Uri.UriSchemeHttps
            || string.IsNullOrWhiteSpace(url.Host)
            || !string.IsNullOrEmpty(url.UserInfo))
            throw new ArgumentException("Connector base URL must be an HTTPS URL without embedded credentials.", nameof(rawUrl));
        if (IPAddress.TryParse(url.Host, out IPAddress? literal))
        {
            if (!PublicHttpsConnectorTransport.IsPublicAddress(literal))
                throw new ArgumentException("Connector base URL must not target a private or reserved address.", nameof(rawUrl));
            return url;
        }
        IPAddress[] addresses = await _resolver(url.Host, cancellationToken).ConfigureAwait(false);
        if (addresses.Length == 0 || addresses.Any(address => !PublicHttpsConnectorTransport.IsPublicAddress(address)))
            throw new ArgumentException("Connector host must resolve exclusively to public addresses.", nameof(rawUrl));
        return url;
    }

    private ConnectorActionResponse Record(StoredConnectorPlane state, ConnectorActionRequest request, bool ok,
        string summary, string? detail, ConnectorHealthStatus status, JsonElement? payload)
    {
        DateTimeOffset now = _clock.UtcNow;
        state.Validations[request.Kind] = new StoredConnectorValidation(status, now, detail ?? summary);
        state = state with { UpdatedAt = now };
        Persist(state);
        return new ConnectorActionResponse(request.Kind, request.Action, ok, summary, detail, payload, now);
    }

    private StoredConnectorPlane Load()
    {
        if (_state is not null) return _state;
        string? json = _stateStore.Read();
        _state = string.IsNullOrWhiteSpace(json)
            ? DefaultState(_clock.UtcNow)
            : JsonSerializer.Deserialize<StoredConnectorPlane>(json, JsonOptions)
                ?? throw new InvalidDataException("Connector plane state is invalid.");
        foreach (ConnectorKind kind in Enum.GetValues<ConnectorKind>())
            _state.Configs.TryAdd(kind, DefaultConfig(kind));
        return _state;
    }

    private void Persist(StoredConnectorPlane state)
    {
        _stateStore.Write(JsonSerializer.Serialize(state, JsonOptions));
        _state = state;
    }

    private ConnectorPlaneSnapshot Snapshot(StoredConnectorPlane state) => new(
        state.UpdatedAt,
        Enum.GetValues<ConnectorKind>().Select(kind =>
        {
            StoredConnectorConfig config = state.Configs[kind];
            StoredConnectorValidation? validation = state.Validations.GetValueOrDefault(kind);
            string? secret = _secrets.Read(kind)?.Trim();
            bool hasSecret = !string.IsNullOrEmpty(secret);
            ConnectorHealthStatus status = !config.IsEnabled ? ConnectorHealthStatus.Disabled
                : !hasSecret ? ConnectorHealthStatus.MissingSecret
                : validation?.Status ?? ConnectorHealthStatus.Configured;
            return new ConnectorConfigSnapshot(kind, DisplayName(kind), config.IsEnabled, config.BaseUrl,
                config.AuthKind, hasSecret, SecretHint(secret), status, validation?.CheckedAt,
                validation?.Detail, Enum.GetValues<ConnectorActionKind>(), config.Metadata);
        }).OrderBy(item => item.DisplayName, StringComparer.Ordinal).ToArray());

    private static StoredConnectorPlane DefaultState(DateTimeOffset now) => new(
        now,
        Enum.GetValues<ConnectorKind>().ToDictionary(kind => kind, DefaultConfig),
        new Dictionary<ConnectorKind, StoredConnectorValidation>());

    private static StoredConnectorConfig DefaultConfig(ConnectorKind kind) => kind switch
    {
        ConnectorKind.Github => Config(kind, "https://api.github.com/", ConnectorAuthKind.BearerToken),
        ConnectorKind.Slack => Config(kind, "https://slack.com/api/", ConnectorAuthKind.BearerToken),
        ConnectorKind.Linear => Config(kind, "https://api.linear.app/graphql", ConnectorAuthKind.BearerToken),
        ConnectorKind.Posthog => Config(kind, "https://app.posthog.com/api/", ConnectorAuthKind.BearerToken),
        ConnectorKind.Sentry => Config(kind, "https://sentry.io/api/0/", ConnectorAuthKind.BearerToken),
        ConnectorKind.Gmail => Config(kind, "https://gmail.googleapis.com/gmail/v1/", ConnectorAuthKind.OAuthAccessToken),
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private static StoredConnectorConfig Config(ConnectorKind kind, string url, ConnectorAuthKind auth) =>
        new(kind, false, url, auth, new Dictionary<string, JsonElement>(StringComparer.Ordinal));

    private static HttpRequestMessage BuildRequest(ConnectorKind kind, Uri baseUrl, string secret)
    {
        Uri endpoint = kind switch
        {
            ConnectorKind.Github => new(baseUrl, "user"),
            ConnectorKind.Slack => new(baseUrl, "auth.test"),
            ConnectorKind.Linear => baseUrl,
            ConnectorKind.Posthog => new(baseUrl, "projects?limit=1"),
            ConnectorKind.Sentry => new(baseUrl, "organizations/"),
            ConnectorKind.Gmail => new(baseUrl, "users/me/profile"),
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
        var request = new HttpRequestMessage(kind is ConnectorKind.Slack or ConnectorKind.Linear ? HttpMethod.Post : HttpMethod.Get, endpoint);
        request.Headers.TryAddWithoutValidation("Authorization", kind == ConnectorKind.Linear ? secret : "Bearer " + secret);
        request.Headers.TryAddWithoutValidation("Accept", "application/json");
        if (kind == ConnectorKind.Linear)
            request.Content = new StringContent("{\"query\":\"{ viewer { id name email } }\"}", Encoding.UTF8, "application/json");
        return request;
    }

    private static (string, string?) Summarize(ConnectorKind kind, JsonElement payload)
    {
        string? Text(JsonElement element, string name) => element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        return kind switch
        {
            ConnectorKind.Github => ($"Connected to GitHub as {Text(payload, "login") ?? "unknown account"}.", Text(payload, "html_url")),
            ConnectorKind.Slack => ($"Connected to Slack workspace {Text(payload, "team") ?? "Slack workspace"}.", Text(payload, "user")),
            ConnectorKind.Gmail => ($"Connected to Gmail as {Text(payload, "emailAddress") ?? "Gmail profile"}.", null),
            ConnectorKind.Linear => ("Connected to Linear.", null),
            ConnectorKind.Posthog => ("Connected to PostHog.", null),
            ConnectorKind.Sentry => ("Connected to Sentry.", null),
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
    }

    private static string DisplayName(ConnectorKind kind) => kind switch
    {
        ConnectorKind.Github => "GitHub",
        ConnectorKind.Posthog => "PostHog",
        _ => kind.ToString(),
    };
    private static string? SecretHint(string? secret) => secret is { Length: >= 4 }
        ? string.Concat(secret.AsSpan(0, 2), "...", secret.AsSpan(secret.Length - 2, 2)) : null;
    private static string Bound(string value, int max) => value.Length <= max ? value : value[..max];
}

public static class ConnectorPlaneComposition
{
    public static ConnectorPlaneService CreateDefault()
    {
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenBurnBar");
        return new ConnectorPlaneService(
            new FileConnectorPlaneStateStore(Path.Combine(root, "connector-plane.json")),
            new ProtectedConnectorSecretStore(ProtectedFileSecretStore.CreateDefault()),
            new PublicHttpsConnectorTransport());
    }
}
