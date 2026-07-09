import { canonicalizeCityKey, deriveGeoKeys } from "./geoCityKey";

type NominatimReverse = {
  address?: {
    city?: string;
    town?: string;
    village?: string;
    state?: string;
    country_code?: string;
  };
};

/** Coarse browser position → canonical cityKey; never returns raw coordinates. */
export async function resolveBrowserCityKey(): Promise<string | undefined> {
  if (typeof window === "undefined" || !navigator.geolocation) {
    return undefined;
  }

  const position = await new Promise<GeolocationPosition>((resolve, reject) => {
    navigator.geolocation.getCurrentPosition(resolve, reject, {
      enableHighAccuracy: false,
      maximumAge: 1_800_000,
      timeout: 20_000,
    });
  }).catch(() => undefined);
  if (!position) return undefined;


  const lat = position.coords.latitude;
  const lon = position.coords.longitude;
  const url = `https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${encodeURIComponent(String(lat))}&lon=${encodeURIComponent(String(lon))}&accept-language=en`;
  let payload: NominatimReverse;
  try {
    const res = await fetch(url, {
      headers: { Accept: "application/json", "User-Agent": "OpenBurnBar-Community/1.0" },
    });
    if (!res.ok) return undefined;
    payload = (await res.json()) as NominatimReverse;
  } catch {
    return undefined;
  }

  const addr = payload.address;
  if (!addr) return undefined;
  const cityName = addr.city ?? addr.town ?? addr.village;
  if (!cityName?.trim()) return undefined;
  const countryCode = addr.country_code?.trim().toUpperCase();
  if (!countryCode) return undefined;
  const regionCode = addr.state?.trim() || countryCode;
  return canonicalizeCityKey(cityName, countryCode, regionCode);
}
