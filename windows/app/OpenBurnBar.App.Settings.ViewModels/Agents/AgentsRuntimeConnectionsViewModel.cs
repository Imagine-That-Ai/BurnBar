// Managed-runtime connection settings (Hermes / Pi) for the Agents → Runtimes surface.
//
// Faithful port of the Hermes/Pi connection fields in ChatGatewaySettingsView.swift +
// ChatBackendSettings store, expressed over the portable ManagedAgentRuntime core
// (windows/app/OpenBurnBar.App.ManagedAgentRuntime): ManagedAgentRuntimeKind gives the
// default gateway URL (Hermes http://127.0.0.1:8642, Pi http://127.0.0.1:8765) + labels.
//   launchWithApp     : Bool = false
//   gatewayBaseURL    : String = <kind default>
//   bearerToken       : String = ""    (secret)
//   remoteRelayEnabled: Bool = false
//   realtimeRelayURL  : String = <hosted relay default>
// URL fields are free text (no in-view validation on macOS); IsGatewayUrlValid is a soft
// signal only.

using System;
using System.Collections.Generic;
using OpenBurnBar.App.ManagedAgentRuntime;

namespace OpenBurnBar.App.Settings.ViewModels.Agents;

/// <summary>The persisted per-runtime connection fields.</summary>
public sealed record AgentRuntimeConnectionSettings(
    bool LaunchWithApp,
    string GatewayBaseUrl,
    string BearerToken,
    bool RemoteRelayEnabled,
    string RealtimeRelayUrl)
{
    /// <summary>Defaults for a runtime kind (gateway URL derives from the kind).</summary>
    public static AgentRuntimeConnectionSettings DefaultFor(ManagedAgentRuntimeKind kind) => new(
        LaunchWithApp: false,
        GatewayBaseUrl: kind.DefaultGatewayBaseUrl().ToString(),
        BearerToken: string.Empty,
        RemoteRelayEnabled: false,
        RealtimeRelayUrl: string.Empty);
}

/// <summary>Loads + persists per-runtime connection settings.</summary>
public interface IAgentRuntimeConnectionsStore
{
    AgentRuntimeConnectionSettings Load(ManagedAgentRuntimeKind kind);

    void Save(ManagedAgentRuntimeKind kind, AgentRuntimeConnectionSettings settings);
}

/// <summary>In-memory runtime-connections store (default for tests).</summary>
public sealed class InMemoryAgentRuntimeConnectionsStore : IAgentRuntimeConnectionsStore
{
    private readonly Dictionary<ManagedAgentRuntimeKind, AgentRuntimeConnectionSettings> _byKind = new();

    public AgentRuntimeConnectionSettings Load(ManagedAgentRuntimeKind kind) =>
        _byKind.TryGetValue(kind, out var s) ? s : AgentRuntimeConnectionSettings.DefaultFor(kind);

    public void Save(ManagedAgentRuntimeKind kind, AgentRuntimeConnectionSettings settings) =>
        _byKind[kind] = settings;
}

/// <summary>Observable connection settings for one managed runtime (Hermes or Pi).</summary>
public sealed class AgentRuntimeConnectionViewModel : ObservableSettingsViewModel
{
    private readonly IAgentRuntimeConnectionsStore _store;

    private bool _launchWithApp;
    private string _gatewayBaseUrl;
    private string _bearerToken = string.Empty;
    private bool _remoteRelayEnabled;
    private string _realtimeRelayUrl = string.Empty;

    public AgentRuntimeConnectionViewModel(ManagedAgentRuntimeKind kind, IAgentRuntimeConnectionsStore store)
    {
        Kind = kind;
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _gatewayBaseUrl = kind.DefaultGatewayBaseUrl().ToString();
        var s = _store.Load(kind);
        _launchWithApp = s.LaunchWithApp;
        _gatewayBaseUrl = s.GatewayBaseUrl;
        _bearerToken = s.BearerToken;
        _remoteRelayEnabled = s.RemoteRelayEnabled;
        _realtimeRelayUrl = s.RealtimeRelayUrl;
    }

    /// <summary>The managed runtime this connection configures.</summary>
    public ManagedAgentRuntimeKind Kind { get; }

    /// <summary>Display name (e.g. "Hermes").</summary>
    public string DisplayName => Kind.DisplayName();

    /// <summary>The default gateway URL for this kind (shown as placeholder).</summary>
    public string DefaultGatewayUrl => Kind.DefaultGatewayBaseUrl().ToString();

    /// <summary>Launch this runtime automatically with OpenBurnBar.</summary>
    public bool LaunchWithApp
    {
        get => _launchWithApp;
        set { if (Set(ref _launchWithApp, value)) { Persist(); } }
    }

    /// <summary>Base URL of the runtime gateway.</summary>
    public string GatewayBaseUrl
    {
        get => _gatewayBaseUrl;
        set
        {
            if (Set(ref _gatewayBaseUrl, value ?? string.Empty))
            {
                Persist();
                OnPropertyChanged(nameof(IsGatewayUrlValid));
            }
        }
    }

    /// <summary>Bearer token used to authenticate to the gateway (secret).</summary>
    public string BearerToken
    {
        get => _bearerToken;
        set { if (Set(ref _bearerToken, value ?? string.Empty)) { Persist(); } }
    }

    /// <summary>Reach the runtime through the cloud relay.</summary>
    public bool RemoteRelayEnabled
    {
        get => _remoteRelayEnabled;
        set { if (Set(ref _remoteRelayEnabled, value)) { Persist(); } }
    }

    /// <summary>The realtime relay URL.</summary>
    public string RealtimeRelayUrl
    {
        get => _realtimeRelayUrl;
        set { if (Set(ref _realtimeRelayUrl, value ?? string.Empty)) { Persist(); } }
    }

    /// <summary>Soft signal: whether the gateway URL parses as an absolute URI.</summary>
    public bool IsGatewayUrlValid =>
        Uri.TryCreate(_gatewayBaseUrl, UriKind.Absolute, out _);

    private void Persist() =>
        _store.Save(Kind, new AgentRuntimeConnectionSettings(
            _launchWithApp, _gatewayBaseUrl, _bearerToken, _remoteRelayEnabled, _realtimeRelayUrl));
}

/// <summary>Aggregates the managed-runtime connections (one per <see cref="ManagedAgentRuntimeKind"/>).</summary>
public sealed class AgentsRuntimeConnectionsViewModel
{
    public AgentsRuntimeConnectionsViewModel(IAgentRuntimeConnectionsStore? store = null)
    {
        var backing = store ?? new InMemoryAgentRuntimeConnectionsStore();
        var connections = new List<AgentRuntimeConnectionViewModel>();
        foreach (var kind in Enum.GetValues<ManagedAgentRuntimeKind>())
        {
            connections.Add(new AgentRuntimeConnectionViewModel(kind, backing));
        }

        Connections = connections;
    }

    /// <summary>The per-runtime connection view-models (Hermes, Pi).</summary>
    public IReadOnlyList<AgentRuntimeConnectionViewModel> Connections { get; }

    /// <summary>Fetch the connection for a specific runtime kind.</summary>
    public AgentRuntimeConnectionViewModel For(ManagedAgentRuntimeKind kind)
    {
        foreach (var connection in Connections)
        {
            if (connection.Kind == kind)
            {
                return connection;
            }
        }

        throw new ArgumentOutOfRangeException(nameof(kind), kind, "No connection for runtime kind.");
    }
}
