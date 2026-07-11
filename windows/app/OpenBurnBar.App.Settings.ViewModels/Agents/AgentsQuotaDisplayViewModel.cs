// Quota-popover display preferences for the Agents tab.
//
// Faithful port of QuotaDisplaySettingsPanel (AgentsSettingsView.swift) + the backing
// QuotaSettings store:
//   cumulativeAcrossAccounts : Bool = false
//   visibleProviders : Set<AgentProvider>   (default: every quota-signal provider)
//   providerOrder    : [AgentProvider]      (CSV; default order)
// Actions: setProvider(visible:), showAllProviders(), resetProviderOrder(), reorder.

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using OpenBurnBar.App.Settings;

namespace OpenBurnBar.App.Settings.ViewModels.Agents;

/// <summary>The persisted quota-display preferences.</summary>
public sealed record QuotaDisplaySnapshot(
    bool CumulativeAcrossAccounts,
    IReadOnlyList<AgentProvider> ProviderOrder,
    IReadOnlyCollection<AgentProvider> VisibleProviders);

/// <summary>Loads + persists the quota-display preferences.</summary>
public interface IQuotaDisplayStore
{
    QuotaDisplaySnapshot? Load();

    void Save(QuotaDisplaySnapshot snapshot);
}

/// <summary>In-memory quota-display store (default for tests).</summary>
public sealed class InMemoryQuotaDisplayStore : IQuotaDisplayStore
{
    private QuotaDisplaySnapshot? _snapshot;

    public InMemoryQuotaDisplayStore(QuotaDisplaySnapshot? seed = null) => _snapshot = seed;

    public QuotaDisplaySnapshot? Load() => _snapshot;

    public void Save(QuotaDisplaySnapshot snapshot) => _snapshot = snapshot;
}

/// <summary>One provider row in the quota-popover configurator (provider + visible flag).</summary>
public sealed class QuotaProviderRow
{
    public QuotaProviderRow(AgentProvider provider, bool isVisible)
    {
        Provider = provider;
        IsVisible = isVisible;
    }

    public AgentProvider Provider { get; }

    public string DisplayName => AgentProviderMetadata.DisplayName(Provider);

    public bool IsVisible { get; internal set; }
}

/// <summary>Backs the "Quota Popover" sub-panel of the Agents tab.</summary>
public sealed class AgentsQuotaDisplayViewModel : ObservableSettingsViewModel
{
    private readonly IQuotaDisplayStore _store;
    private readonly IReadOnlyList<AgentProvider> _universe;

    private bool _cumulativeAcrossAccounts;
    private List<AgentProvider> _order = new();
    private HashSet<AgentProvider> _visible = new();

    public AgentsQuotaDisplayViewModel(
        IReadOnlyList<AgentProvider>? providerUniverse = null,
        IQuotaDisplayStore? store = null)
    {
        _universe = providerUniverse ?? AgentProviderMetadata.AllCases;
        _store = store ?? new InMemoryQuotaDisplayStore();
        Load();
    }

    /// <summary>The ordered provider rows the configurator renders.</summary>
    public ObservableCollection<QuotaProviderRow> Rows { get; } = new();

    /// <summary>Load persisted preferences (defaulting to "all visible, universe order").</summary>
    public void Load()
    {
        var snapshot = _store.Load();
        _cumulativeAcrossAccounts = snapshot?.CumulativeAcrossAccounts ?? false;
        _order = ResolveOrder(snapshot?.ProviderOrder);
        _visible = snapshot is null
            ? new HashSet<AgentProvider>(_universe)
            : new HashSet<AgentProvider>(snapshot.VisibleProviders.Where(_universe.Contains));
        RebuildRows();
        OnPropertyChanged(nameof(CumulativeAcrossAccounts));
    }

    /// <summary>Whether quota is summed across all accounts of a provider.</summary>
    public bool CumulativeAcrossAccounts
    {
        get => _cumulativeAcrossAccounts;
        set { if (Set(ref _cumulativeAcrossAccounts, value)) { Persist(); } }
    }

    /// <summary>Providers currently shown in the menu-bar quota popover, in order.</summary>
    public IReadOnlyList<AgentProvider> VisibleProviders =>
        _order.Where(_visible.Contains).ToArray();

    /// <summary>Number of providers currently visible.</summary>
    public int VisibleCount => _visible.Count;

    /// <summary>Show or hide a provider in the popover.</summary>
    public void SetProviderVisible(AgentProvider provider, bool visible)
    {
        if (!_universe.Contains(provider))
        {
            return;
        }

        bool changed = visible ? _visible.Add(provider) : _visible.Remove(provider);
        if (changed)
        {
            var row = Rows.FirstOrDefault(r => r.Provider == provider);
            if (row is not null)
            {
                row.IsVisible = visible;
            }

            Persist();
            OnPropertyChanged(nameof(VisibleProviders));
            OnPropertyChanged(nameof(VisibleCount));
        }
    }

    /// <summary>Make every provider visible (Swift <c>showAllProviders</c>).</summary>
    public void ShowAllProviders()
    {
        _visible = new HashSet<AgentProvider>(_universe);
        foreach (var row in Rows)
        {
            row.IsVisible = true;
        }

        Persist();
        OnPropertyChanged(nameof(VisibleProviders));
        OnPropertyChanged(nameof(VisibleCount));
    }

    /// <summary>Reset the provider order to the default (Swift <c>resetProviderOrder</c>).</summary>
    public void ResetProviderOrder()
    {
        _order = _universe.ToList();
        RebuildRows();
        Persist();
        OnPropertyChanged(nameof(VisibleProviders));
    }

    /// <summary>Move a provider up/down in the popover order.</summary>
    public void MoveProvider(AgentProvider provider, bool up)
    {
        int index = _order.IndexOf(provider);
        if (index < 0)
        {
            return;
        }

        int target = up ? index - 1 : index + 1;
        if (target < 0 || target >= _order.Count)
        {
            return;
        }

        (_order[index], _order[target]) = (_order[target], _order[index]);
        RebuildRows();
        Persist();
        OnPropertyChanged(nameof(VisibleProviders));
    }

    private List<AgentProvider> ResolveOrder(IReadOnlyList<AgentProvider>? stored)
    {
        var order = new List<AgentProvider>();
        if (stored is not null)
        {
            order.AddRange(stored.Where(p => _universe.Contains(p) && !order.Contains(p)));
        }

        // Append any universe providers missing from the stored order (new providers).
        order.AddRange(_universe.Where(p => !order.Contains(p)));
        return order;
    }

    private void RebuildRows()
    {
        Rows.Clear();
        foreach (var provider in _order)
        {
            Rows.Add(new QuotaProviderRow(provider, _visible.Contains(provider)));
        }
    }

    private void Persist() =>
        _store.Save(new QuotaDisplaySnapshot(_cumulativeAcrossAccounts, _order.ToArray(), _visible.ToArray()));
}
