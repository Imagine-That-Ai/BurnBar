using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;

namespace OpenBurnBar.App.Presentation.Budget;

// PORTED from AgentLens/Services/DataStore/BudgetSettings.swift — the observable façade the
// macOS Settings UI binds to (@Observable @MainActor final class). The WinUI BudgetPage
// x:Binds to this; the gate reads through it (it implements IBudgetRuleProvider). Analytics /
// UserNotifications / legacy-migration side effects are macOS integrations layered in later;
// this is the local read + partition + write-with-audit-event core, fully unit-tested on macOS.

/// <summary>
/// Observable, storage-backed budget-rule model. Implements <see cref="IBudgetRuleProvider"/>
/// so <see cref="BudgetGate"/> reads through it. Every write stamps the rule, records a
/// <see cref="BudgetEvent"/>, and refreshes the in-memory caches the UI observes.
/// </summary>
public sealed class BudgetSettingsModel : INotifyPropertyChanged, IBudgetRuleProvider
{
    private readonly IBudgetRuleStore _store;
    private readonly string _deviceId;
    private readonly Func<DateTimeOffset> _now;

    private IReadOnlyList<BudgetRule> _rules = Array.Empty<BudgetRule>();
    private IReadOnlyList<BudgetEvent> _recentEventCache = Array.Empty<BudgetEvent>();

    public BudgetSettingsModel(IBudgetRuleStore store, string deviceId = "windows-devhost", Func<DateTimeOffset>? now = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _deviceId = deviceId;
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>Every enabled rule (the in-memory cache the UI + gate observe).</summary>
    public IReadOnlyList<BudgetRule> Rules => _rules;

    /// <summary>Grouped, observable collections the WinUI list sections bind to.</summary>
    public ObservableCollection<BudgetRule> GlobalRuleItems { get; } = new();

    public ObservableCollection<BudgetRule> CredentialRuleItems { get; } = new();

    public ObservableCollection<BudgetRule> ProjectRuleItems { get; } = new();

    public ObservableCollection<BudgetEvent> RecentEventItems { get; } = new();

    // MARK: - IBudgetRuleProvider partitioning (mirrors BudgetSettings computed vars)

    public IReadOnlyList<BudgetRule> GlobalRules =>
        _rules.Where(r => r.Scope == BudgetRuleScope.Global).ToList();

    public IReadOnlyList<BudgetRule> CredentialRules =>
        _rules.Where(r => r.Scope == BudgetRuleScope.Credential).ToList();

    public IReadOnlyList<BudgetRule> ProjectRules =>
        _rules.Where(r => r.Scope == BudgetRuleScope.Project).ToList();

    public IReadOnlyList<BudgetRule> OrganizationRules =>
        _rules.Where(r => r.Scope == BudgetRuleScope.Organization).ToList();

    /// <summary>Every credential-scope rule for the given (providerId, accountId) pair.</summary>
    public IReadOnlyList<BudgetRule> RulesForCredential(string providerId, string? accountId) =>
        _rules.Where(r =>
        {
            if (r.Scope != BudgetRuleScope.Credential || !string.Equals(r.ProviderId, providerId, StringComparison.Ordinal))
            {
                return false;
            }

            if (accountId is not null)
            {
                return string.Equals(r.AccountId, accountId, StringComparison.Ordinal);
            }

            return string.IsNullOrEmpty(r.AccountId);
        }).ToList();

    /// <summary>Every project-scope rule for the given free-text project name.</summary>
    public IReadOnlyList<BudgetRule> RulesForProject(string projectName) =>
        _rules.Where(r => r.Scope == BudgetRuleScope.Project &&
                          string.Equals(r.ProjectName, projectName, StringComparison.Ordinal)).ToList();

    /// <summary>The most permissive global rule (largest amount). Mirrors <c>primaryGlobalRule</c>.</summary>
    public BudgetRule? PrimaryGlobalRule =>
        _rules.Where(r => r.Scope == BudgetRuleScope.Global)
              .OrderByDescending(r => r.AmountUsd)
              .FirstOrDefault();

    public bool HasAnyRule => _rules.Count > 0;

    // MARK: - Refresh

    /// <summary>Re-reads every enabled rule + recent events from the store.</summary>
    public async Task RefreshAsync()
    {
        try
        {
            _rules = await _store.FetchAllRulesAsync(includeDisabled: false).ConfigureAwait(false);
        }
        catch (Exception)
        {
            _rules = Array.Empty<BudgetRule>();
        }

        try
        {
            _recentEventCache = await _store.RecentEventsAsync(100).ConfigureAwait(false);
        }
        catch (Exception)
        {
            _recentEventCache = Array.Empty<BudgetEvent>();
        }

        PublishCollections();
    }

    // MARK: - Writes

    /// <summary>
    /// Insert or update a rule. Stamps <c>UpdatedAt</c>/<c>SyncedAt</c>/<c>SourceDeviceId</c>,
    /// records a <see cref="BudgetEventKind.RuleCreated"/> or <see cref="BudgetEventKind.RuleUpdated"/>
    /// audit event, and refreshes. Mirrors <c>BudgetSettings.upsertRule</c>.
    /// </summary>
    public async Task<BudgetRule> UpsertRuleAsync(BudgetRule rule, string source = "settings_ui")
    {
        bool isUpdate = _rules.Any(r => string.Equals(r.Id, rule.Id, StringComparison.Ordinal));
        BudgetRule stamped = rule with
        {
            UpdatedAt = _now(),
            SyncedAt = null,
            SourceDeviceId = rule.SourceDeviceId ?? _deviceId,
        };

        await _store.UpsertRuleAsync(stamped).ConfigureAwait(false);
        await _store.RecordEventAsync(new BudgetEvent
        {
            RuleId = stamped.Id,
            Kind = isUpdate ? BudgetEventKind.RuleUpdated : BudgetEventKind.RuleCreated,
            Source = source,
            AmountAtEvent = 0,
            LimitAtEvent = stamped.AmountUsd,
        }).ConfigureAwait(false);

        await RefreshAsync().ConfigureAwait(false);
        return stamped;
    }

    /// <summary>Delete a rule and record a <see cref="BudgetEventKind.RuleDeleted"/> event.</summary>
    public async Task DeleteRuleAsync(string id, string source = "settings_ui")
    {
        BudgetRule? existing = _rules.FirstOrDefault(r => string.Equals(r.Id, id, StringComparison.Ordinal));
        if (existing is null)
        {
            return;
        }

        await _store.DeleteRuleAsync(id).ConfigureAwait(false);
        await _store.RecordEventAsync(new BudgetEvent
        {
            RuleId = id,
            Kind = BudgetEventKind.RuleDeleted,
            Source = source,
            AmountAtEvent = 0,
            LimitAtEvent = existing.AmountUsd,
        }).ConfigureAwait(false);

        await RefreshAsync().ConfigureAwait(false);
    }

    /// <summary>Pause a rule until <paramref name="resumeAt"/> and record a pause event.</summary>
    public async Task PauseRuleAsync(string id, DateTimeOffset resumeAt, string source = "settings_ui")
    {
        BudgetRule? rule = _rules.FirstOrDefault(r => string.Equals(r.Id, id, StringComparison.Ordinal));
        if (rule is null)
        {
            return;
        }

        await UpsertRuleAsync(rule with { PausedUntil = resumeAt }, source).ConfigureAwait(false);
        await _store.RecordEventAsync(new BudgetEvent
        {
            RuleId = id,
            Kind = BudgetEventKind.Pause,
            Source = source,
            AmountAtEvent = 0,
            LimitAtEvent = rule.AmountUsd,
        }).ConfigureAwait(false);
        await RefreshAsync().ConfigureAwait(false);
    }

    /// <summary>Clear a rule's pause and record a resume event.</summary>
    public async Task ResumeRuleAsync(string id, string source = "settings_ui")
    {
        BudgetRule? rule = _rules.FirstOrDefault(r => string.Equals(r.Id, id, StringComparison.Ordinal));
        if (rule is null)
        {
            return;
        }

        await UpsertRuleAsync(rule with { PausedUntil = null }, source).ConfigureAwait(false);
        await _store.RecordEventAsync(new BudgetEvent
        {
            RuleId = id,
            Kind = BudgetEventKind.Resume,
            Source = source,
            AmountAtEvent = 0,
            LimitAtEvent = rule.AmountUsd,
        }).ConfigureAwait(false);
        await RefreshAsync().ConfigureAwait(false);
    }

    // MARK: - Reads

    /// <summary>Recent audit events, optionally filtered to one rule. Mirrors <c>recentEvents</c>.</summary>
    public IReadOnlyList<BudgetEvent> RecentEvents(string? ruleId = null, int limit = 100)
    {
        IEnumerable<BudgetEvent> events = ruleId is null
            ? _recentEventCache
            : _recentEventCache.Where(e => string.Equals(e.RuleId, ruleId, StringComparison.Ordinal));
        return events.Take(Math.Max(0, limit)).ToList();
    }

    private void PublishCollections()
    {
        Replace(GlobalRuleItems, GlobalRules);
        Replace(CredentialRuleItems, CredentialRules);
        Replace(ProjectRuleItems, ProjectRules);
        Replace(RecentEventItems, RecentEvents(limit: 8));

        OnPropertyChanged(nameof(Rules));
        OnPropertyChanged(nameof(GlobalRules));
        OnPropertyChanged(nameof(CredentialRules));
        OnPropertyChanged(nameof(ProjectRules));
        OnPropertyChanged(nameof(PrimaryGlobalRule));
        OnPropertyChanged(nameof(HasAnyRule));
    }

    private static void Replace<T>(ObservableCollection<T> target, IReadOnlyList<T> source)
    {
        target.Clear();
        foreach (T item in source)
        {
            target.Add(item);
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
