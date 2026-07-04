using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;

namespace OpenBurnBar.Integrations.SmartHub.Bridge;

// The /state.json contract renderer.
//
// Parity: AgentLens/Services/SmartHub/SmartHubBridgeServer.swift
//   stateJSON() + providerJSON(_:) + escape(_:) + persistedTokenForName(_:).
//
// The Nest Hub page does `await r.json()`, so this is whitespace-insensitive
// JSON; we keep the SAME keys, value formats, ordering, tone raw-values, and
// backslash+quote escaping as the Swift emitter (asserted by parsing the output
// in the test suite). The provider filter honors displayConfig.ProviderIds
// (case-insensitive, empty == all) against both the display name and its
// persisted-token slug.

public static class BridgeStateJson
{
    public static string Render(
        ulong version,
        DateTimeOffset lastRefreshedAt,
        bool isRefreshing,
        SmartHubTimePeriod timePeriod,
        SmartHubBridgeSnapshot snapshot,
        SmartHubDisplayConfig displayConfig)
    {
        var allowed = new HashSet<string>(displayConfig.ProviderIds.Select(id => id.ToLowerInvariant()));
        var providers = snapshot.Providers.Where(provider =>
        {
            if (allowed.Count == 0)
            {
                return true;
            }
            return allowed.Contains(provider.Name.ToLowerInvariant())
                || allowed.Contains(PersistedTokenForName(provider.Name));
        }).ToList();

        var providersJson = string.Join(",", providers.Select(ProviderJson));

        var timePeriodOptions = string.Join(",", SmartHubTimePeriodExtensions.AllCases.Select(period =>
            $"{{\"value\":\"{period.RawValue()}\",\"short\":\"{period.ShortLabel()}\",\"name\":\"{Escape(period.DisplayName())}\"}}"));

        var providerIdsJson = string.Join(",", displayConfig.ProviderIds.Select(id => $"\"{Escape(id)}\""));
        var (top, bottom) = displayConfig.Theme.BackgroundPair();

        var displayJson =
            "{" +
            $"\"layout\":\"{displayConfig.Layout.RawValue()}\"," +
            $"\"palette\":\"{displayConfig.Palette.RawValue()}\"," +
            $"\"paletteHex\":{{\"primary\":\"{displayConfig.Palette.PrimaryHex()}\",\"secondary\":\"{displayConfig.Palette.SecondaryHex()}\",\"rainbow\":{Bool(displayConfig.Palette.IsRainbow())}}}," +
            $"\"theme\":\"{displayConfig.Theme.RawValue()}\"," +
            $"\"themeHex\":{{\"top\":\"{top}\",\"bottom\":\"{bottom}\",\"text\":\"{displayConfig.Theme.TextHex()}\"}}," +
            $"\"background\":\"{displayConfig.Background.RawValue()}\"," +
            $"\"brightness\":{Number(displayConfig.ClampedBrightness)}," +
            $"\"scrollSpeedSeconds\":{displayConfig.ClampedScrollSpeed}," +
            $"\"refreshCadenceSeconds\":{displayConfig.ClampedRefreshCadence}," +
            $"\"providerIDs\":[{providerIdsJson}]," +
            $"\"audibleCue\":{Bool(displayConfig.AudibleCue)}," +
            $"\"identifyOnRefresh\":{Bool(displayConfig.IdentifyOnRefresh)}" +
            "}";

        return
            "{" +
            $"\"version\":{version}," +
            $"\"lastRefreshedAt\":\"{Iso8601(lastRefreshedAt)}\"," +
            $"\"isRefreshing\":{Bool(isRefreshing)}," +
            $"\"timePeriod\":\"{timePeriod.RawValue()}\"," +
            $"\"timePeriodLabel\":\"{Escape(timePeriod.DisplayName())}\"," +
            $"\"timePeriodOptions\":[{timePeriodOptions}]," +
            $"\"totalSpend\":\"{Escape(snapshot.TotalSpend)}\"," +
            $"\"totalTokens\":\"{Escape(snapshot.TotalTokens)}\"," +
            $"\"headline\":\"{Escape(snapshot.Headline)}\"," +
            $"\"subheadline\":\"{Escape(snapshot.Subheadline)}\"," +
            $"\"headerTimestamp\":\"{Escape(snapshot.HeaderTimestamp)}\"," +
            $"\"headerStatus\":\"{Escape(snapshot.HeaderStatus)}\"," +
            $"\"providers\":[{providersJson}]," +
            $"\"display\":{displayJson}" +
            "}";
    }

    /// Parity: Swift `providerJSON(_:)` — one provider card with nested bucket /
    /// account / burn-rate arrays.
    public static string ProviderJson(SmartHubProvider p)
    {
        var bucketsJson = string.Join(",", p.Buckets.Select(BucketJson));
        var accountsJson = string.Join(",", p.Accounts.Select(AccountJson));
        var burnRatesJson = string.Join(",", p.BurnRates.Select(BurnRateJson));

        return
            "{" +
            $"\"name\":\"{Escape(p.Name)}\",\"slug\":\"{Escape(p.Slug)}\",\"percent\":{p.Percent},\"label\":\"{Escape(p.Label)}\",\"tone\":\"{p.Tone.RawValue()}\",\"window\":\"{Escape(p.WindowLabel)}\",\"accentHex\":\"{Escape(p.AccentHex)}\"," +
            $"\"logoSVG\":\"{Escape(p.LogoSvg)}\",\"tokenTotal\":\"{Escape(p.TokenTotal)}\",\"tokenTotalCurrency\":\"{Escape(p.TokenTotalCurrency)}\",\"tokenTotalLabel\":\"{Escape(p.TokenTotalLabel)}\",\"statusPill\":\"{Escape(p.StatusPill)}\",\"statusTone\":\"{p.StatusTone.RawValue()}\"," +
            $"\"freshnessLabel\":\"{Escape(p.FreshnessLabel)}\",\"fetchedAtLabel\":\"{Escape(p.FetchedAtLabel)}\",\"runsLabel\":\"{Escape(p.RunsLabel)}\",\"costLabel\":\"{Escape(p.CostLabel)}\",\"hasQuotaData\":{Bool(p.HasQuotaData)}," +
            $"\"buckets\":[{bucketsJson}],\"accounts\":[{accountsJson}],\"burnRates\":[{burnRatesJson}]" +
            "}";
    }

    private static string BucketJson(SmartHubBucket b) =>
        $"{{\"name\":\"{Escape(b.Name)}\",\"percent\":{b.Percent},\"headlineValue\":\"{Escape(b.HeadlineValue)}\",\"subLabel\":\"{Escape(b.SubLabel)}\",\"resetsLabel\":\"{Escape(b.ResetsLabel)}\",\"tone\":\"{b.Tone.RawValue()}\",\"isCreditBalance\":{Bool(b.IsCreditBalance)}}}";

    private static string AccountJson(SmartHubAccount a)
    {
        var accountBuckets = string.Join(",", a.Buckets.Select(BucketJson));
        return $"{{\"label\":\"{Escape(a.Label)}\",\"badge\":\"{Escape(a.Badge)}\",\"tone\":\"{a.Tone.RawValue()}\",\"isActive\":{Bool(a.IsActive)},\"percent\":{a.Percent},\"buckets\":[{accountBuckets}]}}";
    }

    private static string BurnRateJson(SmartHubBurnRate r) =>
        $"{{\"windowLabel\":\"{Escape(r.WindowLabel)}\",\"tokens\":\"{Escape(r.Tokens)}\",\"cost\":\"{Escape(r.Cost)}\",\"runs\":\"{Escape(r.Runs)}\"}}";

    /// Parity: Swift `escape(_:)` — backslash then double-quote only.
    public static string Escape(string s) =>
        s.Replace("\\", "\\\\", StringComparison.Ordinal).Replace("\"", "\\\"", StringComparison.Ordinal);

    /// Parity: Swift `persistedTokenForName(_:)` — lowercase, alphanumerics only.
    public static string PersistedTokenForName(string name)
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

    private static string Bool(bool value) => value ? "true" : "false";

    private static string Number(double value) => value.ToString(CultureInfo.InvariantCulture);

    /// Internet date-time in UTC with a trailing Z (parity with the Swift
    /// ISO8601DateFormatter default, [.withInternetDateTime]).
    public static string Iso8601(DateTimeOffset value) =>
        value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);
}
