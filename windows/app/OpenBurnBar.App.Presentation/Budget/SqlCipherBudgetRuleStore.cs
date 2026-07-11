using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Data.Sqlite;
using OpenBurnBar.Storage;

namespace OpenBurnBar.App.Presentation.Budget;

/// <summary>SQLCipher-backed <see cref="IBudgetRuleStore"/> over Mac <c>budget_rules</c> / <c>budget_events</c>.</summary>
public sealed class SqlCipherBudgetRuleStore : IBudgetRuleStore, IDisposable
{
    private readonly SqliteConnection _connection;

    public SqlCipherBudgetRuleStore(string databasePath, string passphrase)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(databasePath);
        ArgumentException.ThrowIfNullOrWhiteSpace(passphrase);
        _connection = SqlCipherConnection.Open(databasePath, passphrase);
    }

    public void Dispose() => _connection.Dispose();

    public Task<IReadOnlyList<BudgetRule>> FetchAllRulesAsync(bool includeDisabled, CancellationToken cancellationToken = default)
    {
        var rows = BudgetRuleWriteSeam.FetchAllRules(_connection, includeDisabled);
        IReadOnlyList<BudgetRule> rules = rows
            .Select(MapRule)
            .OrderBy(r => r.CreatedAt)
            .ThenBy(r => r.Id, StringComparer.Ordinal)
            .ToList();
        return Task.FromResult(rules);
    }

    public Task UpsertRuleAsync(BudgetRule rule, CancellationToken cancellationToken = default)
    {
        BudgetRuleWriteSeam.UpsertRule(_connection, MapRuleRow(rule));
        return Task.CompletedTask;
    }

    public Task DeleteRuleAsync(string id, CancellationToken cancellationToken = default)
    {
        BudgetRuleWriteSeam.DeleteRule(_connection, id);
        return Task.CompletedTask;
    }

    public Task RecordEventAsync(BudgetEvent budgetEvent, CancellationToken cancellationToken = default)
    {
        BudgetRuleWriteSeam.InsertEvent(_connection, MapEventRow(budgetEvent));
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<BudgetEvent>> RecentEventsAsync(int limit, CancellationToken cancellationToken = default)
    {
        var rows = BudgetRuleWriteSeam.FetchRecentEvents(_connection, limit);
        IReadOnlyList<BudgetEvent> events = rows.Select(MapEvent).ToList();
        return Task.FromResult(events);
    }

    private static BudgetRule MapRule(BudgetRuleRow row) => new()
    {
        Id = row.Id,
        Scope = BudgetEnumRaw.ParseScope(row.Scope),
        Identifier = row.Identifier,
        ProviderId = row.ProviderId,
        AccountId = row.AccountId,
        ProjectName = row.ProjectName,
        Label = row.Label,
        AmountUsd = row.AmountUsd,
        Period = BudgetEnumRaw.ParsePeriod(row.Period),
        Behavior = BudgetEnumRaw.ParseBehavior(row.Behavior),
        FallbackCredentialIds = row.FallbackCredentialIds.ToList(),
        PausedUntil = row.PausedUntil,
        CreatedAt = row.CreatedAt,
        UpdatedAt = row.UpdatedAt,
        SyncedAt = row.SyncedAt,
        SourceDeviceId = row.SourceDeviceId,
        IsEnabled = row.IsEnabled,
    };

    private static BudgetEvent MapEvent(BudgetEventRow row) => new()
    {
        Id = row.Id,
        RuleId = row.RuleId,
        Kind = ParseEventKind(row.Kind),
        Source = row.Source,
        AmountAtEvent = row.AmountAtEvent,
        LimitAtEvent = row.LimitAtEvent,
        DetailJson = row.DetailJson,
        OccurredAt = row.OccurredAt,
        SyncedAt = row.SyncedAt,
        SourceDeviceId = row.SourceDeviceId,
    };

    private static BudgetEventKind ParseEventKind(string raw) => raw switch
    {
        "warning" => BudgetEventKind.Warning,
        "block" => BudgetEventKind.Block,
        "override" => BudgetEventKind.Override,
        "pause" => BudgetEventKind.Pause,
        "resume" => BudgetEventKind.Resume,
        "ruleCreated" => BudgetEventKind.RuleCreated,
        "ruleUpdated" => BudgetEventKind.RuleUpdated,
        "ruleDeleted" => BudgetEventKind.RuleDeleted,
        _ => BudgetEventKind.Warning,
    };

    private static BudgetRuleRow MapRuleRow(BudgetRule rule) => new(
        Id: rule.Id,
        Scope: rule.Scope.Raw(),
        Identifier: rule.Identifier,
        ProviderId: rule.ProviderId,
        AccountId: rule.AccountId,
        ProjectName: rule.ProjectName,
        Label: rule.Label,
        AmountUsd: rule.AmountUsd,
        Period: rule.Period.Raw(),
        Behavior: rule.Behavior.Raw(),
        FallbackCredentialIds: rule.FallbackCredentialIds,
        PausedUntil: rule.PausedUntil,
        CreatedAt: rule.CreatedAt,
        UpdatedAt: rule.UpdatedAt,
        SyncedAt: rule.SyncedAt,
        SourceDeviceId: rule.SourceDeviceId,
        IsEnabled: rule.IsEnabled);

    private static BudgetEventRow MapEventRow(BudgetEvent budgetEvent) => new(
        Id: budgetEvent.Id,
        RuleId: budgetEvent.RuleId,
        Kind: budgetEvent.Kind.Raw(),
        Source: budgetEvent.Source,
        AmountAtEvent: budgetEvent.AmountAtEvent,
        LimitAtEvent: budgetEvent.LimitAtEvent,
        DetailJson: budgetEvent.DetailJson,
        OccurredAt: budgetEvent.OccurredAt,
        SyncedAt: budgetEvent.SyncedAt,
        SourceDeviceId: budgetEvent.SourceDeviceId);
}