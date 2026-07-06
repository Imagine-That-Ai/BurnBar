// View-model for the Model Proxy settings tab.
//
// Faithful port of AgentLens/Views/Settings/ModelProxySettingsView.swift + the backing
// GatewaySettings store (AgentLens/Services/Settings/Stores/GatewaySettings.swift):
//   gatewayEnabled : Bool  = false
//   gatewayHost    : String = "127.0.0.1"
//   gatewayPort    : Int    = 8317
//   gatewayAuthToken : String = ""      (secret)
//   gatewayAllowUnauthenticatedLoopback : Bool = false
// Loopback hosts are {127.0.0.1, localhost, ::1}; the auth token is only optional when
// the bind is loopback AND unauthenticated-loopback is opted in. Persistence lives
// behind IGatewayEndpointStore (Windows AppConfiguration, WPD-0006 row 23); the "Copy
// endpoint" clipboard write is an injected seam.

using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Settings.ViewModels;

/// <summary>The five persisted local-gateway fields (GatewaySettings).</summary>
public sealed record GatewayEndpointSettings(
    bool Enabled,
    string Host,
    int Port,
    string AuthToken,
    bool AllowUnauthenticatedLoopback)
{
    /// <summary>The macOS/Windows defaults.</summary>
    public static readonly GatewayEndpointSettings Default = new(
        Enabled: false,
        Host: "127.0.0.1",
        Port: 8317,
        AuthToken: string.Empty,
        AllowUnauthenticatedLoopback: false);
}

/// <summary>Loads + persists the local-gateway settings (WinUI: AppConfiguration-backed).</summary>
public interface IGatewayEndpointStore
{
    /// <summary>Read the current settings (returns <see cref="GatewayEndpointSettings.Default"/> when unset).</summary>
    GatewayEndpointSettings Load();

    /// <summary>Persist the settings.</summary>
    void Save(GatewayEndpointSettings settings);
}

/// <summary>In-memory gateway store (default for tests).</summary>
public sealed class InMemoryGatewayEndpointStore : IGatewayEndpointStore
{
    private GatewayEndpointSettings _settings;

    public InMemoryGatewayEndpointStore(GatewayEndpointSettings? seed = null) =>
        _settings = seed ?? GatewayEndpointSettings.Default;

    /// <inheritdoc />
    public GatewayEndpointSettings Load() => _settings;

    /// <inheritdoc />
    public void Save(GatewayEndpointSettings settings) => _settings = settings;
}

/// <summary>Backs the Model Proxy tab (local OpenAI-compatible gateway endpoint + routing).</summary>
public sealed class ModelProxySettingsViewModel : ObservableSettingsViewModel
{
    /// <summary>Hosts treated as loopback (Swift <c>isLoopback</c> set).</summary>
    public static readonly IReadOnlyList<string> LoopbackHosts = new[] { "127.0.0.1", "localhost", "::1" };

    /// <summary>Lowest / highest legal TCP port.</summary>
    public const int MinPort = 1;
    public const int MaxPort = 65535;

    private readonly IGatewayEndpointStore _store;
    private readonly ISettingsClipboard _clipboard;

    private bool _enabled;
    private string _host = GatewayEndpointSettings.Default.Host;
    private int _port = GatewayEndpointSettings.Default.Port;
    private string _authToken = string.Empty;
    private bool _allowUnauthenticatedLoopback;
    private bool _copiedEndpoint;

    public ModelProxySettingsViewModel(
        IGatewayEndpointStore? store = null,
        ISettingsClipboard? clipboard = null)
    {
        _store = store ?? new InMemoryGatewayEndpointStore();
        _clipboard = clipboard ?? new NullSettingsClipboard();
        Load();
    }

    /// <summary>Load persisted settings into the view-model.</summary>
    public void Load()
    {
        var s = _store.Load();
        _enabled = s.Enabled;
        _host = s.Host;
        _port = s.Port;
        _authToken = s.AuthToken;
        _allowUnauthenticatedLoopback = s.AllowUnauthenticatedLoopback;
        _copiedEndpoint = false;
        RaiseAll();
    }

    /// <summary>Whether the local gateway is enabled.</summary>
    public bool Enabled
    {
        get => _enabled;
        set { if (Set(ref _enabled, value)) { Persist(); } }
    }

    /// <summary>Bind address for the gateway server.</summary>
    public string Host
    {
        get => _host;
        set
        {
            if (Set(ref _host, value ?? string.Empty))
            {
                Persist();
                RaiseEndpointDerived();
            }
        }
    }

    /// <summary>TCP port the gateway listens on (clamped to <see cref="MinPort"/>..<see cref="MaxPort"/>).</summary>
    public int Port
    {
        get => _port;
        set
        {
            var clamped = Math.Clamp(value, MinPort, MaxPort);
            if (Set(ref _port, clamped))
            {
                Persist();
                RaiseEndpointDerived();
            }
        }
    }

    /// <summary>Bearer token required for non-loopback (or authenticated-loopback) bindings.</summary>
    public string AuthToken
    {
        get => _authToken;
        set
        {
            if (Set(ref _authToken, value ?? string.Empty))
            {
                Persist();
                OnPropertyChanged(nameof(HasAuthToken));
                OnPropertyChanged(nameof(AuthTokenWarning));
                OnPropertyChanged(nameof(HasAuthTokenWarning));
            }
        }
    }

    /// <summary>Allow serving loopback binds without an auth token.</summary>
    public bool AllowUnauthenticatedLoopback
    {
        get => _allowUnauthenticatedLoopback;
        set
        {
            if (Set(ref _allowUnauthenticatedLoopback, value))
            {
                Persist();
                OnPropertyChanged(nameof(AuthTokenRequired));
                OnPropertyChanged(nameof(AuthTokenWarning));
                OnPropertyChanged(nameof(HasAuthTokenWarning));
            }
        }
    }

    /// <summary>Host:port endpoint (Swift <c>endpoint</c>).</summary>
    public string Endpoint => $"{_host}:{_port}";

    /// <summary>The full copyable base URL, e.g. <c>http://127.0.0.1:8317/v1</c>.</summary>
    public string EndpointUrl => $"http://{Endpoint}/v1";

    /// <summary>Whether the bind address is loopback.</summary>
    public bool IsLoopback => LoopbackHosts.Contains(_host, StringComparer.OrdinalIgnoreCase);

    /// <summary>Whether an auth token is required for the current bind.</summary>
    public bool AuthTokenRequired => !(IsLoopback && _allowUnauthenticatedLoopback);

    /// <summary>Whether a token is set.</summary>
    public bool HasAuthToken => !string.IsNullOrEmpty(_authToken);

    /// <summary>Whether the host field is non-empty (bind address validity).</summary>
    public bool IsHostValid => !string.IsNullOrWhiteSpace(_host);

    /// <summary>
    /// A soft warning when a token is required but not yet set. Not blocking — the daemon
    /// auto-generates one on next launch — but the tab surfaces it so the operator knows.
    /// </summary>
    public string? AuthTokenWarning =>
        AuthTokenRequired && !HasAuthToken
            ? "A gateway auth token is required for this bind; one will be generated on next launch."
            : null;

    /// <summary>Whether <see cref="AuthTokenWarning"/> is present.</summary>
    public bool HasAuthTokenWarning => AuthTokenWarning is not null;

    /// <summary>Whether the "endpoint copied" confirmation should show.</summary>
    public bool CopiedEndpoint
    {
        get => _copiedEndpoint;
        private set => Set(ref _copiedEndpoint, value);
    }

    /// <summary>Copy the base URL to the clipboard and flip the copied confirmation.</summary>
    public void CopyEndpoint()
    {
        _clipboard.WriteText(EndpointUrl);
        CopiedEndpoint = true;
    }

    private void Persist() =>
        _store.Save(new GatewayEndpointSettings(_enabled, _host, _port, _authToken, _allowUnauthenticatedLoopback));

    private void RaiseEndpointDerived()
    {
        CopiedEndpoint = false;
        OnPropertyChanged(nameof(Endpoint));
        OnPropertyChanged(nameof(EndpointUrl));
        OnPropertyChanged(nameof(IsLoopback));
        OnPropertyChanged(nameof(AuthTokenRequired));
        OnPropertyChanged(nameof(IsHostValid));
        OnPropertyChanged(nameof(AuthTokenWarning));
        OnPropertyChanged(nameof(HasAuthTokenWarning));
    }

    private void RaiseAll()
    {
        OnPropertyChanged(nameof(Enabled));
        OnPropertyChanged(nameof(Host));
        OnPropertyChanged(nameof(Port));
        OnPropertyChanged(nameof(AuthToken));
        OnPropertyChanged(nameof(AllowUnauthenticatedLoopback));
        OnPropertyChanged(nameof(HasAuthToken));
        RaiseEndpointDerived();
    }
}
