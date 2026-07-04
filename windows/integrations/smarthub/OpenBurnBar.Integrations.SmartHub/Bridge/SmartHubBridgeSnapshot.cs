using System;
using System.Collections.Generic;
using System.Text;

namespace OpenBurnBar.Integrations.SmartHub.Bridge;

// Rich per-provider snapshot the Nest Hub renders.
//
// Parity: AgentLens/Services/SmartHub/SmartHubBridgeServer.swift
//   struct SmartHubBridgeSnapshot + Provider/Bucket/Account/BurnRate/Tone,
//   including the slug-from-name derivation and the field defaults.

public enum SmartHubTone { Ember, Whimsy, Success, Warning, Mercury }

public static class SmartHubToneExtensions
{
    public static string RawValue(this SmartHubTone tone) => tone switch
    {
        SmartHubTone.Ember => "ember",
        SmartHubTone.Whimsy => "whimsy",
        SmartHubTone.Success => "success",
        SmartHubTone.Warning => "warning",
        SmartHubTone.Mercury => "mercury",
        _ => "mercury",
    };
}

public sealed record SmartHubBucket(
    string Name,
    int Percent,
    string HeadlineValue,
    string SubLabel,
    string ResetsLabel,
    SmartHubTone Tone,
    bool IsCreditBalance);

public sealed record SmartHubAccount(
    string Label,
    string Badge,
    SmartHubTone Tone,
    bool IsActive,
    IReadOnlyList<SmartHubBucket> Buckets,
    int Percent)
{
    public SmartHubAccount(string label, string badge, SmartHubTone tone, bool isActive)
        : this(label, badge, tone, isActive, Array.Empty<SmartHubBucket>(), 0)
    {
    }
}

public sealed record SmartHubBurnRate(
    string WindowLabel,
    string Tokens,
    string Cost,
    string Runs);

public sealed class SmartHubProvider
{
    public string Name { get; }
    public int Percent { get; }
    public string Label { get; }
    public SmartHubTone Tone { get; }
    public string WindowLabel { get; }
    public string Slug { get; }
    public string AccentHex { get; }
    public string LogoSvg { get; }
    public string TokenTotal { get; }
    public string TokenTotalCurrency { get; }
    public string TokenTotalLabel { get; }
    public string StatusPill { get; }
    public SmartHubTone StatusTone { get; }
    public string FreshnessLabel { get; }
    public string FetchedAtLabel { get; }
    public IReadOnlyList<SmartHubBucket> Buckets { get; }
    public IReadOnlyList<SmartHubAccount> Accounts { get; }
    public string RunsLabel { get; }
    public string CostLabel { get; }
    public bool HasQuotaData { get; }
    public IReadOnlyList<SmartHubBurnRate> BurnRates { get; }

    public SmartHubProvider(
        string name,
        int percent,
        string label,
        SmartHubTone tone,
        string windowLabel = "",
        string slug = "",
        string accentHex = "",
        string logoSvg = "",
        string tokenTotal = "",
        string tokenTotalCurrency = "",
        string tokenTotalLabel = "TOKENS",
        string statusPill = "",
        SmartHubTone statusTone = SmartHubTone.Mercury,
        string freshnessLabel = "",
        string fetchedAtLabel = "",
        IReadOnlyList<SmartHubBucket>? buckets = null,
        IReadOnlyList<SmartHubAccount>? accounts = null,
        string runsLabel = "",
        string costLabel = "",
        bool hasQuotaData = true,
        IReadOnlyList<SmartHubBurnRate>? burnRates = null)
    {
        Name = name;
        Percent = percent;
        Label = label;
        Tone = tone;
        WindowLabel = windowLabel;
        Slug = string.IsNullOrEmpty(slug) ? SlugForName(name) : slug;
        AccentHex = accentHex;
        LogoSvg = logoSvg;
        TokenTotal = tokenTotal;
        TokenTotalCurrency = tokenTotalCurrency;
        TokenTotalLabel = tokenTotalLabel;
        StatusPill = statusPill;
        StatusTone = statusTone;
        FreshnessLabel = freshnessLabel;
        FetchedAtLabel = fetchedAtLabel;
        Buckets = buckets ?? Array.Empty<SmartHubBucket>();
        Accounts = accounts ?? Array.Empty<SmartHubAccount>();
        RunsLabel = runsLabel;
        CostLabel = costLabel;
        HasQuotaData = hasQuotaData;
        BurnRates = burnRates ?? Array.Empty<SmartHubBurnRate>();
    }

    /// Parity: Swift `Provider.slug(forName:)` — lowercase, keep alphanumerics.
    public static string SlugForName(string name)
    {
        var sb = new StringBuilder(name.Length);
        foreach (var ch in name.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(ch))
            {
                sb.Append(ch);
            }
        }
        return sb.ToString();
    }
}

public sealed class SmartHubBridgeSnapshot
{
    public string TotalSpend { get; }
    public string TotalTokens { get; }
    public string Headline { get; }
    public string Subheadline { get; }
    public IReadOnlyList<SmartHubProvider> Providers { get; }
    public string HeaderTimestamp { get; }
    public string HeaderStatus { get; }

    public SmartHubBridgeSnapshot(
        string totalSpend,
        string headline,
        string subheadline,
        IReadOnlyList<SmartHubProvider> providers,
        string totalTokens = "",
        string headerTimestamp = "",
        string headerStatus = "")
    {
        TotalSpend = totalSpend;
        TotalTokens = totalTokens;
        Headline = headline;
        Subheadline = subheadline;
        Providers = providers;
        HeaderTimestamp = headerTimestamp;
        HeaderStatus = headerStatus;
    }

    /// Parity: Swift `SmartHubBridgeSnapshot.empty`.
    public static SmartHubBridgeSnapshot Empty { get; } = new(
        totalSpend: "—",
        headline: "OpenBurnBar",
        subheadline: "Waiting for first sync…",
        providers: Array.Empty<SmartHubProvider>());
}
