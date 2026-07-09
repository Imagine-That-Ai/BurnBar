using System.Globalization;

namespace OpenBurnBar.App.Community;

/// <summary>
/// Builds join/updateCommunityProfile callable payloads including device timezone and locale.
/// </summary>
public static class CommunityJoinPayload
{
    public static (string Timezone, string Locale) DeviceGeoKeys()
    {
        string timezone = TimeZoneInfo.Local.Id;
        string locale = CultureInfo.CurrentCulture.Name;
        return (timezone, locale);
    }

    public static Dictionary<string, object?> BuildJoinPayload(
        CommunityConsentState state,
        string? handle = null,
        string? countryCode = null,
        string? regionKey = null,
        string? cityKey = null)
    {
        string? wireCityKey = null;
        if (state.L2Tiers.City.IsActive() && state.LocationConsent.IsActive() && !string.IsNullOrWhiteSpace(cityKey))
        {
            wireCityKey = cityKey.Trim();
        }

        return BuildJoinPayloadCore(state, handle, countryCode, regionKey, wireCityKey);
    }

    public static async Task<Dictionary<string, object?>> BuildJoinPayloadWithOsCityAsync(
        CommunityConsentState state,
        CancellationToken cancellationToken = default,
        string? handle = null,
        string? countryCode = null,
        string? regionKey = null)
    {
        string? cityKey = null;
        if (state.L2Tiers.City.IsActive() && state.LocationConsent.IsActive())
        {
            cityKey = await CommunityLocationResolver.TryResolveCityKeyAsync(cancellationToken).ConfigureAwait(false);
        }

        return BuildJoinPayload(state, handle, countryCode, regionKey, cityKey);
    }

    public static Dictionary<string, object?> BuildUpdateProfileGeoPayload()
    {
        var (timezone, locale) = DeviceGeoKeys();
        return new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["timezone"] = timezone,
            ["locale"] = locale,
        };
    }

    private static Dictionary<string, object?> BuildJoinPayloadCore(
        CommunityConsentState state,
        string? handle,
        string? countryCode,
        string? regionKey,
        string? cityKey)
    {
        var (timezone, locale) = DeviceGeoKeys();
        var payload = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["l1Analytics"] = Wire(state.L1Analytics),
            ["l2Rankings"] = Wire(state.L2Rankings),
            ["l2World"] = Wire(state.L2Tiers.World),
            ["l2Country"] = Wire(state.L2Tiers.Country),
            ["l2Region"] = Wire(state.L2Tiers.Region),
            ["l2City"] = Wire(state.L2Tiers.City),
            ["locationConsent"] = Wire(state.LocationConsent),
            ["l3LookingGlass"] = Wire(state.L3LookingGlass),
            ["timezone"] = timezone,
            ["locale"] = locale,
        };
        if (!string.IsNullOrWhiteSpace(handle))
        {
            payload["handle"] = handle.Trim();
        }
        if (!string.IsNullOrWhiteSpace(countryCode))
        {
            payload["countryCode"] = countryCode;
        }
        if (!string.IsNullOrWhiteSpace(regionKey))
        {
            payload["regionKey"] = regionKey;
        }
        if (!string.IsNullOrWhiteSpace(cityKey))
        {
            payload["cityKey"] = cityKey;
        }
        return payload;
    }

    private static string Wire(ConsentTriState state) =>
        state == ConsentTriState.Granted ? "granted" : "declined";
}