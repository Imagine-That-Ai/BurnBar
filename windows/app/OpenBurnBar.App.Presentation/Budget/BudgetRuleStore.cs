using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Budget;

// PORTED from AgentLens/Services/DataStore/BudgetRulesStore.swift (persistence seam) and the
// in-memory cache behavior of BudgetSettings.swift. The store interface is the seam a later
// wave backs with the shared SQLCipher DataStore (OpenBurnBar.Storage); the in-memory
// implementation here powers both the dev-host page and the macOS unit tests.

/// <summary>Persistence seam for budget rules + the append-only audit log.</summary>
public interface IBudgetRuleStore
{
    Task<IReadOnlyList<BudgetRule>> FetchAllRulesAsync(bool includeDisabled, CancellationToken cancellationToken = default);
    Task UpsertRuleAsync(BudgetRule rule, CancellationToken cancellationToken = default);
    Task DeleteRuleAsync(string id, CancellationToken cancellationToken = default);
    Task RecordEventAsync(BudgetEvent budgetEvent, CancellationToken cancellationToken = default);
    Task<IReadOnlyList<BudgetEvent>> RecentEventsAsync(int limit, CancellationToken cancellationToken = default);
}

/// <summary>
/// Deterministic in-memory <see cref="IBudgetRuleStore"/>. Rules keyed by id; events kept in
/// insertion order and returned newest-first. Faithful to the store contract the Swift
/// <c>BudgetRulesStore</c> exposes (fetch/upsert/delete/recordEvent/recentEvents).
/// </summary>
public sealed class InMemoryBudgetRuleStore : IBudgetRuleStore
{
    private readonly Dictionary<string, BudgetRule> _rules = new(StringComparer.Ordinal);
    private readonly List<BudgetEvent> _events = new();

    public InMemoryBudgetRuleStore(IEnumerable<BudgetRule>? seed = null)
    {
        if (seed is null)
        {
            return;
        }

        foreach (BudgetRule rule in seed)
        {
            _rules[rule.Id] = rule;
        }
    }

    public Task<IReadOnlyList<BudgetRule>> FetchAllRulesAsync(bool includeDisabled, CancellationToken cancellationToken = default)
    {
        IReadOnlyList<BudgetRule> result = _rules.Values
            .Where(r => includeDisabled || r.IsEnabled)
            .OrderBy(r => r.CreatedAt)
            .ThenBy(r => r.Id, StringComparer.Ordinal)
            .ToList();
        return Task.FromResult(result);
    }

    public Task UpsertRuleAsync(BudgetRule rule, CancellationToken cancellationToken = default)
    {
        _rules[rule.Id] = rule;
        return Task.CompletedTask;
    }

    public Task DeleteRuleAsync(string id, CancellationToken cancellationToken = default)
    {
        _rules.Remove(id);
        return Task.CompletedTask;
    }

    public Task RecordEventAsync(BudgetEvent budgetEvent, CancellationToken cancellationToken = default)
    {
        _events.Add(budgetEvent);
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<BudgetEvent>> RecentEventsAsync(int limit, CancellationToken cancellationToken = default)
    {
        IReadOnlyList<BudgetEvent> result = _events
            .AsEnumerable()
            .Reverse()
            .Take(Math.Max(0, limit))
            .ToList();
        return Task.FromResult(result);
    }
}
