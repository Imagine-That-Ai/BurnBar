using System.Globalization;
using System.Text.RegularExpressions;

namespace OpenBurnBar.App.Community;

/// <summary>
/// Ports timezone/locale <c>deriveGeoKeys</c> from <c>functions/src/community/geo.ts</c> (country/region tiers).
/// </summary>
public static class CommunityGeoKeys
{
    private static readonly IReadOnlyDictionary<string, string> TzToCountry = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["America/New_York"] = "US",
        ["America/Chicago"] = "US",
        ["America/Denver"] = "US",
        ["America/Los_Angeles"] = "US",
        ["America/Phoenix"] = "US",
        ["America/Anchorage"] = "US",
        ["Pacific/Honolulu"] = "US",
        ["America/Toronto"] = "CA",
        ["America/Vancouver"] = "CA",
        ["Europe/London"] = "GB",
        ["Europe/Berlin"] = "DE",
        ["Asia/Tokyo"] = "JP",
    };

    private static readonly IReadOnlyDictionary<string, string> TzToRegion = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["America/New_York"] = "US-NY",
        ["America/Chicago"] = "US-IL",
        ["America/Denver"] = "US-CO",
        ["America/Los_Angeles"] = "US-CA",
        ["America/Phoenix"] = "US-AZ",
        ["America/Anchorage"] = "US-AK",
        ["Pacific/Honolulu"] = "US-HI",
        ["America/Toronto"] = "CA-ON",
        ["America/Vancouver"] = "CA-BC",
    };

    private static readonly Regex LocaleRegion = new(@"[-_]([A-Z]{2})\b", RegexOptions.Compiled);

    public static (string? CountryCode, string? RegionKey) Derive(string timezone, string locale)
    {
        TzToCountry.TryGetValue(timezone, out var tzCountry);
        TzToRegion.TryGetValue(timezone, out var tzRegion);
        string? localeCountry = null;
        var m = LocaleRegion.Match(locale);
        if (m.Success)
        {
            localeCountry = m.Groups[1].Value;
        }

        return (tzCountry ?? localeCountry, tzRegion);
    }

    public static string RegionCodeFromRegionKey(string? regionKey, string countryCode)
    {
        if (string.IsNullOrWhiteSpace(regionKey))
        {
            return countryCode;
        }

        var rk = regionKey.Trim().ToUpperInvariant();
        var dash = rk.IndexOf('-', StringComparison.Ordinal);
        return dash >= 0 ? rk[(dash + 1)..] : rk;
    }
}