/**
 * Ports functions/src/community/geo.ts city key canonicalization + deriveGeoKeys.
 */

export interface GeoKeys {
  countryCode?: string;
  regionKey?: string;
}

const TZ_TO_COUNTRY: Record<string, string> = {
  "America/New_York": "US",
  "America/Chicago": "US",
  "America/Denver": "US",
  "America/Los_Angeles": "US",
  "America/Phoenix": "US",
  "America/Anchorage": "US",
  "Pacific/Honolulu": "US",
  "America/Toronto": "CA",
  "America/Vancouver": "CA",
  "America/Halifax": "CA",
  "America/Edmonton": "CA",
  "America/Winnipeg": "CA",
  "America/Mexico_City": "MX",
  "America/Cancun": "MX",
  "America/Sao_Paulo": "BR",
  "America/Argentina/Buenos_Aires": "AR",
  "America/Santiago": "CL",
  "America/Bogota": "CO",
  "America/Lima": "PE",
  "Europe/London": "GB",
  "Europe/Dublin": "IE",
  "Europe/Paris": "FR",
  "Europe/Berlin": "DE",
  "Europe/Madrid": "ES",
  "Europe/Italy": "IT",
  "Europe/Rome": "IT",
  "Europe/Amsterdam": "NL",
  "Europe/Brussels": "BE",
  "Europe/Vienna": "AT",
  "Europe/Zurich": "CH",
  "Europe/Stockholm": "SE",
  "Europe/Oslo": "NO",
  "Europe/Copenhagen": "DK",
  "Europe/Helsinki": "FI",
  "Europe/Warsaw": "PL",
  "Europe/Prague": "CZ",
  "Europe/Budapest": "HU",
  "Europe/Lisbon": "PT",
  "Europe/Athens": "GR",
  "Europe/Istanbul": "TR",
  "Europe/Moscow": "RU",
  "Europe/Kiev": "UA",
  "Europe/Kyiv": "UA",
  "Asia/Tokyo": "JP",
  "Asia/Shanghai": "CN",
  "Asia/Hong_Kong": "HK",
  "Asia/Taipei": "TW",
  "Asia/Singapore": "SG",
  "Asia/Seoul": "KR",
  "Asia/Bangkok": "TH",
  "Asia/Jakarta": "ID",
  "Asia/Manila": "PH",
  "Asia/Kuala_Lumpur": "MY",
  "Asia/Ho_Chi_Minh": "VN",
  "Asia/Kolkata": "IN",
  "Asia/Karachi": "PK",
  "Asia/Dubai": "AE",
  "Asia/Tehran": "IR",
  "Asia/Jerusalem": "IL",
  "Asia/Riyadh": "SA",
  "Australia/Sydney": "AU",
  "Australia/Melbourne": "AU",
  "Australia/Brisbane": "AU",
  "Australia/Perth": "AU",
  "Pacific/Auckland": "NZ",
  "Africa/Cairo": "EG",
  "Africa/Lagos": "NG",
  "Africa/Johannesburg": "ZA",
  "Africa/Nairobi": "KE",
  "Africa/Casablanca": "MA",
  "Africa/Accra": "GH",
};

const TZ_TO_REGION: Record<string, string> = {
  "America/New_York": "US-NY",
  "America/Chicago": "US-IL",
  "America/Denver": "US-CO",
  "America/Los_Angeles": "US-CA",
  "America/Phoenix": "US-AZ",
  "America/Anchorage": "US-AK",
  "Pacific/Honolulu": "US-HI",
  "America/Toronto": "CA-ON",
  "America/Vancouver": "CA-BC",
  "America/Halifax": "CA-NS",
  "America/Edmonton": "CA-AB",
  "America/Winnipeg": "CA-MB",
  "Australia/Sydney": "AU-NSW",
  "Australia/Melbourne": "AU-VIC",
  "Australia/Brisbane": "AU-QLD",
  "Australia/Perth": "AU-WA",
};

export function deriveGeoKeys(timezone: string, locale: string): GeoKeys {
  const tzCountry = TZ_TO_COUNTRY[timezone];
  const tzRegion = TZ_TO_REGION[timezone];
  let localeCountry: string | undefined;
  for (const part of locale.split(/[-_]/).slice(1)) {
    if (part.length === 1) break;
    if (/^[A-Za-z]{2}$/.test(part)) {
      localeCountry = part.toUpperCase();
      break;
    }
  }
  return {
    countryCode: tzCountry ?? localeCountry,
    regionKey: tzRegion,
  };
}
/**
 * Non-decomposable Unicode characters that NFD does NOT reduce to ASCII.
 * Replaced identically on every platform before NFD (ports functions/src/community/geo.ts).
 */
const NON_DECOMPOSABLE: Record<string, string> = {
  "\u00d8": "O",
  "\u00f8": "o",
  "\u0141": "L",
  "\u0142": "l",
  "\u00d0": "D",
  "\u00f0": "d",
  "\u00de": "T",
  "\u00fe": "t",
  "\u00df": "ss",
  "\u0130": "I",
  "\u0131": "i",
  "\u0110": "D",
  "\u0111": "d",
  "\u014a": "N",
  "\u014b": "n",
  "\u017d": "Z",
  "\u017e": "z",
  "\u0160": "S",
  "\u0161": "s",
  "\u015a": "S",
  "\u015b": "s",
  "\u017b": "Z",
  "\u017c": "z",
  "\u0106": "C",
  "\u0107": "c",
  "\u010c": "C",
  "\u010d": "c",
  "\u0158": "R",
  "\u0159": "r",
  "\u016e": "U",
  "\u016f": "u",
  "\u0147": "N",
  "\u0148": "n",
  "\u010e": "D",
  "\u010f": "d",
  "\u0164": "T",
  "\u0165": "t",
};

export function asciiFold(input: string): string {
  let out = input;
  for (const [from, to] of Object.entries(NON_DECOMPOSABLE)) {
    out = out.split(from).join(to);
  }
  return out.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
}

export function slugifyCity(cityName: string): string {
  return asciiFold(cityName)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40)
    .replace(/-+$/g, "");
}

export function canonicalizeCityKey(cityName: string, countryCode: string, regionCode: string): string {
  const cc = countryCode.trim().toUpperCase();
  let rc = regionCode.trim().toUpperCase();
  if (rc.startsWith(`${cc}-`)) {
    rc = rc.slice(cc.length + 1);
  }
  return `${cc}-${rc}-${slugifyCity(cityName)}`;
}

export function cityKeyFromManualCityInput(cityInput: string, timezone: string, locale: string): string | undefined {
  const trimmed = cityInput.trim();
  if (!trimmed) return undefined;
  const geo = deriveGeoKeys(timezone, locale);
  if (!geo.countryCode) return undefined;
  const regionCode = geo.regionKey?.includes("-") ? geo.regionKey.split("-")[1]! : geo.countryCode;
  return canonicalizeCityKey(trimmed, geo.countryCode, regionCode);
}