using System;

namespace OpenBurnBar.App.Presentation.Budget;

// PORTED from BudgetEventKind / BudgetEvent in
// OpenBurnBarCore/.../SharedModels/BudgetRule.swift — the append-only audit log that feeds
// the "Recent activity" section of the Budget surface and (later) the burnbar_budget_audit
// table. Pure value types; no storage dependency.

/// <summary>Audit-log entry kinds. Mirrors Swift <c>BudgetEventKind</c>.</summary>
public enum BudgetEventKind
{
    Warning,
    Block,
    Override,
    Pause,
    Resume,
    RuleCreated,
    RuleUpdated,
    RuleDeleted,
}

/// <summary>Raw-value parity for the audit-kind column.</summary>
public static class BudgetEventKindRaw
{
    public static string Raw(this BudgetEventKind kind) => kind switch
    {
        BudgetEventKind.Warning => "warning",
        BudgetEventKind.Block => "block",
        BudgetEventKind.Override => "override",
        BudgetEventKind.Pause => "pause",
        BudgetEventKind.Resume => "resume",
        BudgetEventKind.RuleCreated => "ruleCreated",
        BudgetEventKind.RuleUpdated => "ruleUpdated",
        BudgetEventKind.RuleDeleted => "ruleDeleted",
        _ => "warning",
    };
}

/// <summary>Single immutable audit-log row. Mirrors Swift <c>BudgetEvent</c>.</summary>
public sealed record BudgetEvent
{
    public string Id { get; init; } = Guid.NewGuid().ToString();
    public string RuleId { get; init; } = string.Empty;
    public BudgetEventKind Kind { get; init; }

    /// <summary>Origin — e.g. "settings_ui", "hermes_tool", "auto_gate". Free-form.</summary>
    public string? Source { get; init; }

    public double AmountAtEvent { get; init; }
    public double LimitAtEvent { get; init; }
    public string? DetailJson { get; init; }
    public DateTimeOffset OccurredAt { get; init; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? SyncedAt { get; init; }
    public string? SourceDeviceId { get; init; }
}
