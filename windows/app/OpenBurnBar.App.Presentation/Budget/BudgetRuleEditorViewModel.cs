using System;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace OpenBurnBar.App.Presentation.Budget;

// PORTED from AgentLens/Views/Settings/BudgetSettingsView.swift — the BudgetRuleEditorSheet /
// BudgetRuleEditorView Form state + the save-disabled validation. The WinUI
// BudgetRuleEditorDialog two-way binds to these properties; Build() produces the rule to hand
// to BudgetSettingsModel.UpsertRuleAsync. Pure, no WinUI dependency; unit-tested on macOS.

/// <summary>
/// Editable draft of a <see cref="BudgetRule"/>. Preserves the source rule's identity/timestamps
/// so an edit updates in place, and exposes <see cref="SaveDisabled"/> exactly as the Swift
/// editor's <c>saveDisabled</c> computed property.
/// </summary>
public sealed class BudgetRuleEditorViewModel : INotifyPropertyChanged
{
    private readonly BudgetRule _source;
    private readonly bool _isNew;

    private string _label;
    private double _amountUsd;
    private BudgetPeriod _period;
    private BudgetBehavior _behavior;
    private bool _isEnabled;
    private string _providerId;
    private string _accountId;
    private string _projectName;

    private BudgetRuleEditorViewModel(BudgetRule source, bool isNew)
    {
        _source = source;
        _isNew = isNew;
        _label = source.Label ?? string.Empty;
        _amountUsd = source.AmountUsd;
        _period = source.Period;
        _behavior = source.Behavior;
        _isEnabled = source.IsEnabled;
        _providerId = source.ProviderId ?? string.Empty;
        _accountId = source.AccountId ?? string.Empty;
        _projectName = source.ProjectName ?? string.Empty;
    }

    /// <summary>A blank draft for a new rule of the given scope (amount $50 / monthly default).</summary>
    public static BudgetRuleEditorViewModel ForNewRule(BudgetRuleScope scope) =>
        new(new BudgetRule { Scope = scope, AmountUsd = 50, Period = BudgetPeriod.Month }, isNew: true);

    /// <summary>An editable draft over an existing rule.</summary>
    public static BudgetRuleEditorViewModel ForExisting(BudgetRule rule) => new(rule, isNew: false);

    public BudgetRuleScope Scope => _source.Scope;

    public bool IsNew => _isNew;

    public bool IsCredentialScope => Scope == BudgetRuleScope.Credential;

    public bool IsProjectScope => Scope == BudgetRuleScope.Project;

    public string ScopeRaw => Scope.Raw();

    public string Label
    {
        get => _label;
        set => Set(ref _label, value ?? string.Empty);
    }

    public double AmountUsd
    {
        get => _amountUsd;
        set
        {
            if (Set(ref _amountUsd, value))
            {
                OnPropertyChanged(nameof(SaveDisabled));
            }
        }
    }

    public BudgetPeriod Period
    {
        get => _period;
        set => Set(ref _period, value);
    }

    public BudgetBehavior Behavior
    {
        get => _behavior;
        set => Set(ref _behavior, value);
    }

    public bool IsEnabled
    {
        get => _isEnabled;
        set => Set(ref _isEnabled, value);
    }

    public string ProviderId
    {
        get => _providerId;
        set
        {
            if (Set(ref _providerId, value ?? string.Empty))
            {
                OnPropertyChanged(nameof(SaveDisabled));
            }
        }
    }

    public string AccountId
    {
        get => _accountId;
        set => Set(ref _accountId, value ?? string.Empty);
    }

    public string ProjectName
    {
        get => _projectName;
        set
        {
            if (Set(ref _projectName, value ?? string.Empty))
            {
                OnPropertyChanged(nameof(SaveDisabled));
            }
        }
    }

    /// <summary>
    /// Mirrors the Swift editor's <c>saveDisabled</c>: a non-positive amount is invalid; a
    /// credential rule needs a provider; a project rule needs a project name.
    /// </summary>
    public bool SaveDisabled
    {
        get
        {
            if (_amountUsd <= 0)
            {
                return true;
            }

            if (Scope == BudgetRuleScope.Credential && string.IsNullOrEmpty(_providerId.Trim()))
            {
                return true;
            }

            if (Scope == BudgetRuleScope.Project && string.IsNullOrEmpty(_projectName.Trim()))
            {
                return true;
            }

            return false;
        }
    }

    public bool CanSave => !SaveDisabled;

    /// <summary>Produce the rule reflecting the current edits (empty text fields collapse to null).</summary>
    public BudgetRule Build() => _source with
    {
        Label = Nullify(_label),
        AmountUsd = _amountUsd,
        Period = _period,
        Behavior = _behavior,
        IsEnabled = _isEnabled,
        ProviderId = IsCredentialScope ? Nullify(_providerId) : _source.ProviderId,
        AccountId = IsCredentialScope ? Nullify(_accountId) : _source.AccountId,
        ProjectName = IsProjectScope ? Nullify(_projectName) : _source.ProjectName,
    };

    private static string? Nullify(string value)
    {
        string trimmed = value.Trim();
        return trimmed.Length == 0 ? null : trimmed;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (System.Collections.Generic.EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        OnPropertyChanged(name);
        return true;
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
