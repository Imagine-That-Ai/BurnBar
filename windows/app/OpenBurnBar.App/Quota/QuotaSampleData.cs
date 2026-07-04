using System;
using System.Collections.Generic;
using OpenBurnBar.App.Components;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Quota;

/// <summary>
/// Representative sample subscriptions for the Quota workspace preview. Live wiring to the ported
/// ProviderQuotaService is a later Phase-3 lane; this stands in exactly as <c>StubCliStream</c> does
/// for the Session Logs surface, so the parity-tested visuals render against realistic data on the
/// dev host today. Pure (no WinUI); the dial buckets align with each account's pressure so an orb's
/// remaining percent and its dial agree.
/// </summary>
public sealed record QuotaSampleAccount(SubscriptionEntry Entry, QuotaDialBucket? Outer, QuotaDialBucket? Inner);

/// <summary>The static sample set the workspace renders.</summary>
public static class QuotaSampleData
{
    /// <summary>Six accounts spanning the health spectrum: wide-open, comfortable, narrowing,
    /// near-edge, an inner-window-missing plan (dashed inner ring), and a no-signal plan (muted orb).</summary>
    public static IReadOnlyList<QuotaSampleAccount> Accounts()
    {
        DateTimeOffset now = DateTimeOffset.Now;

        return new List<QuotaSampleAccount>
        {
            // Wide open.
            Account(AgentProviderBrand.Copilot, "Business", pressure: 0.10, nextReset: now.AddDays(21),
                fetchedAt: now.AddMinutes(-3),
                outer: new QuotaDialBucket(QuotaWindowKind.Monthly, usedPercent: 10, resetsAt: now.AddDays(21)),
                inner: new QuotaDialBucket(QuotaWindowKind.RollingHours, usedPercent: 5, resetsAt: now.AddMinutes(90))),

            // Comfortable / healthy.
            Account(AgentProviderBrand.ClaudeCode, "Max plan", pressure: 0.25, nextReset: now.AddDays(3),
                fetchedAt: now.AddMinutes(-5),
                outer: new QuotaDialBucket(QuotaWindowKind.Weekly, usedPercent: 25, resetsAt: now.AddDays(3)),
                inner: new QuotaDialBucket(QuotaWindowKind.RollingHours, usedPercent: 40, resetsAt: now.AddMinutes(30))),

            // Narrowing.
            Account(AgentProviderBrand.DeepSeek, "Standard", pressure: 0.62, nextReset: now.AddDays(9),
                fetchedAt: now.AddMinutes(-12),
                outer: new QuotaDialBucket(QuotaWindowKind.Monthly, usedPercent: 62, resetsAt: now.AddDays(9)),
                inner: null),

            // Near edge — outer heavily used, inner window missing (dashed inner ring).
            Account(AgentProviderBrand.Codex, "Plus", pressure: 0.88, nextReset: now.AddHours(20),
                fetchedAt: now.AddMinutes(-1),
                outer: new QuotaDialBucket(QuotaWindowKind.Weekly, usedPercent: 88, resetsAt: now.AddHours(20)),
                inner: null),

            // Two-window near-cap plan.
            Account(AgentProviderBrand.Cursor, "Pro", pressure: 0.80, nextReset: now.AddDays(6),
                fetchedAt: now.AddMinutes(-8),
                outer: new QuotaDialBucket(QuotaWindowKind.Monthly, remainingValue: 200_000, limitValue: 1_000_000, resetsAt: now.AddDays(6)),
                inner: new QuotaDialBucket(QuotaWindowKind.Daily, usedPercent: 55, resetsAt: now.AddHours(10))),

            // No displayable signal — muted orb, no dial cards.
            new QuotaSampleAccount(
                new SubscriptionEntry(
                    id: "gemini-cli:default",
                    provider: AgentProviderBrand.GeminiCLI,
                    accountLabel: "CLI",
                    pressure: 0,
                    hasDisplayableBucket: false,
                    fetchedAt: now.AddMinutes(-30)),
                Outer: null,
                Inner: null),
        };
    }

    private static QuotaSampleAccount Account(
        AgentProviderBrand provider,
        string accountLabel,
        double pressure,
        DateTimeOffset nextReset,
        DateTimeOffset fetchedAt,
        QuotaDialBucket? outer,
        QuotaDialBucket? inner) =>
        new(
            new SubscriptionEntry(
                id: $"{provider}:{accountLabel}",
                provider: provider,
                accountLabel: accountLabel,
                pressure: pressure,
                hasDisplayableBucket: true,
                nextResetDate: nextReset,
                fetchedAt: fetchedAt),
            outer,
            inner);
}
