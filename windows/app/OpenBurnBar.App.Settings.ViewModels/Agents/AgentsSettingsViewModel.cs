// Top-level view-model for the Agents tab (the unified Connections + Account Switcher +
// AI Environments surface).
//
// Faithful to the settings-model slices of AgentsSettingsView.swift that have a portable
// backing core on main:
//   • Quota Popover display  → AgentsQuotaDisplayViewModel (QuotaSettings, AgentProvider)
//   • Runtimes & Relays      → AgentsRuntimeConnectionsViewModel (ManagedAgentRuntime #1301)
//   • Model-proxy → Cursor   → the CursorConnector config (#1303): exposed models + tunnel
// The macOS Agents hub also hosts account/CLI/browser-profile surfaces that already have
// their own portable view-models (SwitcherSettingsViewModel, ElderWand*); those are not
// re-implemented here.

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using OpenBurnBar.App.CursorConnector;
using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.ViewModels.Agents;

/// <summary>Loads + persists the Cursor connector config (#1303).</summary>
public interface ICursorConnectorStore
{
    CursorConnectorConfig Load();

    void Save(CursorConnectorConfig config);
}

/// <summary>In-memory Cursor connector store (default for tests).</summary>
public sealed class InMemoryCursorConnectorStore : ICursorConnectorStore
{
    private CursorConnectorConfig _config;

    public InMemoryCursorConnectorStore(CursorConnectorConfig? seed = null) =>
        _config = seed ?? CursorConnectorConfig.CreateDefault();

    public CursorConnectorConfig Load() => _config;

    public void Save(CursorConnectorConfig config) => _config = config;
}

/// <summary>One connector-provider row (provider + enabled + exposed models).</summary>
public sealed class CursorConnectorProviderRow
{
    public CursorConnectorProviderRow(ConnectorProvider provider, bool enabled, IReadOnlyList<string> exposedModels)
    {
        Provider = provider;
        Enabled = enabled;
        ExposedModels = exposedModels;
    }

    public ConnectorProvider Provider { get; }

    public string DisplayName => Provider.Raw();

    public bool Enabled { get; internal set; }

    public IReadOnlyList<string> ExposedModels { get; }
}

/// <summary>Backs the Agents tab: quota-popover, managed runtimes, and the Cursor model-proxy bridge.</summary>
public sealed class AgentsSettingsViewModel : ObservableSettingsViewModel
{
    private readonly ICursorConnectorStore _cursorStore;
    private CursorConnectorConfig _cursor;

    public AgentsSettingsViewModel(
        IReadOnlyList<AgentProvider>? quotaProviderUniverse = null,
        IQuotaDisplayStore? quotaStore = null,
        IAgentRuntimeConnectionsStore? runtimeStore = null,
        ICursorConnectorStore? cursorStore = null)
    {
        QuotaDisplay = new AgentsQuotaDisplayViewModel(quotaProviderUniverse, quotaStore);
        Runtimes = new AgentsRuntimeConnectionsViewModel(runtimeStore);
        _cursorStore = cursorStore ?? new InMemoryCursorConnectorStore();
        _cursor = _cursorStore.Load();
        RebuildConnectorRows();
    }

    /// <summary>The quota-popover display sub-panel.</summary>
    public AgentsQuotaDisplayViewModel QuotaDisplay { get; }

    /// <summary>The managed-runtime (Hermes / Pi) connection sub-panels.</summary>
    public AgentsRuntimeConnectionsViewModel Runtimes { get; }

    // ── Cursor / model-proxy bridge (#1303) ───────────────────────────────────

    /// <summary>Whether the Cursor connector is routing.</summary>
    public bool CursorConnectorEnabled
    {
        get => _cursor.IsEnabled;
        set
        {
            if (value != _cursor.IsEnabled)
            {
                _cursor.IsEnabled = value;
                PersistCursor();
                OnPropertyChanged();
            }
        }
    }

    /// <summary>The local port the connector serves on.</summary>
    public int CursorPreferredPort => _cursor.PreferredPort;

    /// <summary>Every model the connector exposes to Cursor (across enabled providers).</summary>
    public IReadOnlyList<string> CursorExposedModels => _cursor.ExposedModels;

    /// <summary>The connector-provider rows the surface renders.</summary>
    public ObservableCollection<CursorConnectorProviderRow> ConnectorProviders { get; } = new();

    /// <summary>Enable or disable routing a connector provider.</summary>
    public void SetConnectorProviderEnabled(ConnectorProvider provider, bool enabled)
    {
        var config = _cursor.ProviderConfigs.FirstOrDefault(c => c.Id == provider);
        if (config is null || config.Enabled == enabled)
        {
            return;
        }

        config.Enabled = enabled;
        var row = ConnectorProviders.FirstOrDefault(r => r.Provider == provider);
        if (row is not null)
        {
            row.Enabled = enabled;
        }

        PersistCursor();
        OnPropertyChanged(nameof(CursorExposedModels));
    }

    private void RebuildConnectorRows()
    {
        ConnectorProviders.Clear();
        foreach (var config in _cursor.ProviderConfigs)
        {
            ConnectorProviders.Add(new CursorConnectorProviderRow(config.Id, config.Enabled, config.ExposedModels));
        }
    }

    private void PersistCursor() => _cursorStore.Save(_cursor);
}
