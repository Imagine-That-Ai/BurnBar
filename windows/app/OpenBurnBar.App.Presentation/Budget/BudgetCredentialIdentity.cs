using System;

namespace OpenBurnBar.App.Presentation.Budget;

// PORTED from BudgetCredentialIdentity in
// OpenBurnBarCore/.../SharedModels/BudgetRule.swift — the unified credential handle the gate
// uses to look up matching rules and to short-circuit subscription credentials before any
// ledger read.

/// <summary>Unified credential handle used by <see cref="BudgetGate"/> to match rules.</summary>
public sealed record BudgetCredentialIdentity
{
    public BudgetCredentialIdentity(
        string providerId,
        string slotId,
        string displayLabel,
        BudgetBillingMode billingMode = BudgetBillingMode.Unknown)
    {
        ProviderId = providerId;
        SlotId = slotId;
        DisplayLabel = displayLabel;
        BillingMode = billingMode;
    }

    public string ProviderId { get; }
    public string SlotId { get; }
    public string DisplayLabel { get; }
    public BudgetBillingMode BillingMode { get; }

    /// <summary>
    /// Derives the billing mode from a raw secret prefix. Anthropic OAuth keys
    /// (<c>sk-ant-oat*</c>) and token-plan keys (<c>tp-*</c>) are subscription identities and
    /// must never be gated; Console keys (<c>sk-ant-api*</c>) and bearer-style OpenAI keys
    /// (<c>sk-*</c>) are per-usage. Byte-for-byte parity with the Swift static.
    /// </summary>
    public static BudgetBillingMode BillingModeForSecretPrefix(string prefix)
    {
        string lower = (prefix ?? string.Empty).ToLowerInvariant();
        if (lower.StartsWith("sk-ant-oat", StringComparison.Ordinal))
        {
            return BudgetBillingMode.Subscription;
        }

        if (lower.StartsWith("tp-", StringComparison.Ordinal))
        {
            return BudgetBillingMode.Subscription;
        }

        if (lower.StartsWith("sk-ant-api", StringComparison.Ordinal))
        {
            return BudgetBillingMode.PerUsage;
        }

        if (lower.StartsWith("sk-", StringComparison.Ordinal))
        {
            return BudgetBillingMode.PerUsage;
        }

        return BudgetBillingMode.Unknown;
    }
}
