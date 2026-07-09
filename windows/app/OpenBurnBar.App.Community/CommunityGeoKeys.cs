using System.Linq;

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
        ["America/Halifax"] = "CA",
        ["America/Edmonton"] = "CA",
        ["America/Winnipeg"] = "CA",
        ["America/Mexico_City"] = "MX",
        ["America/Cancun"] = "MX",
        ["America/Sao_Paulo"] = "BR",
        ["America/Argentina/Buenos_Aires"] = "AR",
        ["America/Santiago"] = "CL",
        ["America/Bogota"] = "CO",
        ["America/Lima"] = "PE",
        ["Europe/London"] = "GB",
        ["Europe/Dublin"] = "IE",
        ["Europe/Paris"] = "FR",
        ["Europe/Berlin"] = "DE",
        ["Europe/Madrid"] = "ES",
        ["Europe/Italy"] = "IT",
        ["Europe/Rome"] = "IT",
        ["Europe/Amsterdam"] = "NL",
        ["Europe/Brussels"] = "BE",
        ["Europe/Vienna"] = "AT",
        ["Europe/Zurich"] = "CH",
        ["Europe/Stockholm"] = "SE",
        ["Europe/Oslo"] = "NO",
        ["Europe/Copenhagen"] = "DK",
        ["Europe/Helsinki"] = "FI",
        ["Europe/Warsaw"] = "PL",
        ["Europe/Prague"] = "CZ",
        ["Europe/Budapest"] = "HU",
        ["Europe/Lisbon"] = "PT",
        ["Europe/Athens"] = "GR",
        ["Europe/Istanbul"] = "TR",
        ["Europe/Moscow"] = "RU",
        ["Europe/Kiev"] = "UA",
        ["Europe/Kyiv"] = "UA",
        ["Asia/Tokyo"] = "JP",
        ["Asia/Shanghai"] = "CN",
        ["Asia/Hong_Kong"] = "HK",
        ["Asia/Taipei"] = "TW",
        ["Asia/Singapore"] = "SG",
        ["Asia/Seoul"] = "KR",
        ["Asia/Bangkok"] = "TH",
        ["Asia/Jakarta"] = "ID",
        ["Asia/Manila"] = "PH",
        ["Asia/Kuala_Lumpur"] = "MY",
        ["Asia/Ho_Chi_Minh"] = "VN",
        ["Asia/Kolkata"] = "IN",
        ["Asia/Karachi"] = "PK",
        ["Asia/Dubai"] = "AE",
        ["Asia/Tehran"] = "IR",
        ["Asia/Jerusalem"] = "IL",
        ["Asia/Riyadh"] = "SA",
        ["Australia/Sydney"] = "AU",
        ["Australia/Melbourne"] = "AU",
        ["Australia/Brisbane"] = "AU",
        ["Australia/Perth"] = "AU",
        ["Pacific/Auckland"] = "NZ",
        ["Africa/Cairo"] = "EG",
        ["Africa/Lagos"] = "NG",
        ["Africa/Johannesburg"] = "ZA",
        ["Africa/Nairobi"] = "KE",
        ["Africa/Casablanca"] = "MA",
        ["Africa/Accra"] = "GH",
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
        ["America/Halifax"] = "CA-NS",
        ["America/Edmonton"] = "CA-AB",
        ["America/Winnipeg"] = "CA-MB",
        ["Australia/Sydney"] = "AU-NSW",
        ["Australia/Melbourne"] = "AU-VIC",
        ["Australia/Brisbane"] = "AU-QLD",
        ["Australia/Perth"] = "AU-WA",
    };

    public static (string? CountryCode, string? RegionKey) Derive(string timezone, string locale)
    {
        TzToCountry.TryGetValue(timezone, out var tzCountry);
        TzToRegion.TryGetValue(timezone, out var tzRegion);
        string? localeCountry = null;
        foreach (var part in locale.Split(new[] { '-', '_' }, StringSplitOptions.RemoveEmptyEntries).Skip(1))
        {
            if (part.Length == 1)
            {
                break;
            }

            if (part.Length == 2 && part.All(char.IsLetter))
            {
                localeCountry = part.ToUpperInvariant();
                break;
            }
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