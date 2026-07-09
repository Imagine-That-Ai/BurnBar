using Windows.Devices.Geolocation;
using Windows.Services.Maps;

namespace OpenBurnBar.App.Community;

/// <summary>
/// Coarse OS location → canonical <c>cityKey</c> ({country}-{region}-{slug}). Never persists raw coordinates.
/// Reverse-geocode uses fixed <c>en-US</c> culture per shared geo spec.
/// </summary>
public static class CommunityLocationResolver
{

    public static async Task<string?> TryResolveCityKeyAsync(CancellationToken cancellationToken = default)
    {
        var access = await Geolocator.RequestAccessAsync().AsTask(cancellationToken).ConfigureAwait(false);
        if (access != GeolocationAccessStatus.Allowed)
        {
            return null;
        }

        var geolocator = new Geolocator
        {
            DesiredAccuracy = PositionAccuracy.Default,
            DesiredAccuracyInMeters = 3000,
        };

        Geoposition position;
        try
        {
            position = await geolocator
                .GetGeopositionAsync(maximumAge: TimeSpan.FromMinutes(30), timeout: TimeSpan.FromSeconds(20))
                .AsTask(cancellationToken)
                .ConfigureAwait(false);
        }
        catch (UnauthorizedAccessException)
        {
            return null;
        }
        catch (Exception)
        {
            return null;
        }

        var point = position.Coordinate.Point;
        var reverse = await MapLocationFinder
            .FindLocationsAtAsync(point)
            .AsTask(cancellationToken)
            .ConfigureAwait(false);

        if (reverse.Status != MapLocationFinderStatus.Success || reverse.Locations.Count == 0)
        {
            return null;
        }

        var address = reverse.Locations[0].Address;
        if (address is null)
        {
            return null;
        }

        var cityName = address.Town;
        if (string.IsNullOrWhiteSpace(cityName))
        {
            return null;
        }

        var (tz, loc) = CommunityJoinPayload.DeviceGeoKeys();
        var derived = CommunityGeoKeys.Derive(tz, loc);

        var countryCode = address.CountryCode?.Trim().ToUpperInvariant();
        if (string.IsNullOrWhiteSpace(countryCode))
        {
            countryCode = derived.CountryCode;
        }

        if (string.IsNullOrWhiteSpace(countryCode))
        {
            return null;
        }

        var regionCode = address.Region?.Trim();
        if (string.IsNullOrWhiteSpace(regionCode) || regionCode.Length > 3)
        {
            regionCode = CommunityGeoKeys.RegionCodeFromRegionKey(derived.RegionKey, countryCode);
        }

        return CommunityCityKey.CanonicalizeCityKey(cityName, countryCode, regionCode);
    }
}