namespace OpenBurnBar.App.Community;

public static class CommunityGeoDisplay
{
    private static readonly IReadOnlyDictionary<string, string> RegionDisplay = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["US-NY"] = "New York",
        ["US-IL"] = "Illinois",
        ["US-CO"] = "Colorado",
        ["US-CA"] = "California",
        ["US-AZ"] = "Arizona",
        ["US-AK"] = "Alaska",
        ["US-HI"] = "Hawaii",
        ["CA-ON"] = "Ontario",
        ["CA-BC"] = "British Columbia",
        ["CA-NS"] = "Nova Scotia",
        ["CA-AB"] = "Alberta",
        ["CA-MB"] = "Manitoba",
        ["AU-NSW"] = "New South Wales",
        ["AU-VIC"] = "Victoria",
        ["AU-QLD"] = "Queensland",
        ["AU-WA"] = "Western Australia",
    };

    private static readonly IReadOnlyDictionary<string, string> CountryDisplay = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["US"] = "United States",
        ["CA"] = "Canada",
        ["GB"] = "United Kingdom",
        ["DE"] = "Germany",
        ["FR"] = "France",
        ["AU"] = "Australia",
        ["JP"] = "Japan",
    };

    public static string ResolveLabel(CommunityConsentState consent, GeographyTier tier)
    {
        var (timezone, locale) = CommunityJoinPayload.DeviceGeoKeys();
        var derived = CommunityGeoKeys.Derive(timezone, locale);
        var manual = consent.ManualCityInput?.Trim();

        return tier switch
        {
            GeographyTier.City => !string.IsNullOrWhiteSpace(manual)
                ? manual!
                : "City unavailable — add a manual city label",
            GeographyTier.Region => ResolveRegion(derived.RegionKey),
            GeographyTier.Country => ResolveCountry(derived.CountryCode),
            _ => "Global",
        };
    }

    public static string ResolveConfidenceCopy(CommunityConsentState consent, GeographyTier tier)
    {
        var label = ResolveLabel(consent, tier);
        return tier switch
        {
            GeographyTier.City => label.StartsWith("City unavailable", StringComparison.Ordinal)
                ? "City rank waits for explicit city consent and a manual label; no raw coordinates are used."
                : "Manual city label only; BurnBar stores a canonical city key, never raw coordinates.",
            GeographyTier.Region => label.StartsWith("Region unavailable", StringComparison.Ordinal)
                ? "Region unavailable from this device locale/timezone."
                : "Coarse region inferred from device locale/timezone.",
            GeographyTier.Country => label.StartsWith("Country unavailable", StringComparison.Ordinal)
                ? "Country unavailable from this device locale/timezone."
                : "Coarse country inferred from device locale/timezone.",
            _ => "World ranking uses no location signal.",
        };
    }


    private static string ResolveRegion(string? regionKey)
    {
        if (string.IsNullOrWhiteSpace(regionKey))
        {
            return "Region unavailable";
        }

        return RegionDisplay.TryGetValue(regionKey, out var label) ? label : regionKey;
    }

    private static string ResolveCountry(string? countryCode)
    {
        if (string.IsNullOrWhiteSpace(countryCode))
        {
            return "Country unavailable";
        }

        var cc = countryCode.Trim().ToUpperInvariant();
        return CountryDisplay.TryGetValue(cc, out var label) ? label : cc;
    }
}