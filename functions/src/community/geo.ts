/**
 * @fileoverview Timezone/locale-derived geography keys.
 *
 * Spec §4: "Country/region tiers use locale/timezone without any location
 * permission; the OS prompt appears only when enabling city tier."
 *
 * This module derives countryCode and regionKey from the device's locale and
 * timezone — no location permission, no CoreLocation, no network. It covers
 * the world + country + region leaderboard tiers. The city tier additionally
 * requires the OS coarse-location pipeline (separate, platform-specific).
 */

import type { CommunityProfileDoc } from "../types/generated/community.js";

/** Result of locale/timezone-derived geography resolution. */
export interface GeoKeys {
  /** ISO 3166-1 alpha-2 country code (e.g. "US", "GB", "JP"). */
  countryCode?: string;
  /** Region/state key: "{countryCode}-{regionCode}" (e.g. "US-CA", "GB-ENG"). */
  regionKey?: string;
  /** City key — always undefined from locale/timezone (requires OS location). */
  cityKey?: undefined;
}

// ---------------------------------------------------------------------------
// Timezone → country/region mapping (IANA tz database)
// ---------------------------------------------------------------------------

/**
 * Maps IANA timezone identifiers to ISO country codes. Covers the most common
 * zones; missing zones fall through to locale-only resolution. This data is
 * static and deterministic — same timezone → same country on every platform.
 */
const TZ_TO_COUNTRY: Record<string, string> = {
  // North America
  "America/New_York": "US", "America/Chicago": "US", "America/Denver": "US",
  "America/Los_Angeles": "US", "America/Phoenix": "US", "America/Anchorage": "US",
  "Pacific/Honolulu": "US", "America/Toronto": "CA", "America/Vancouver": "CA",
  "America/Halifax": "CA", "America/Edmonton": "CA", "America/Winnipeg": "CA",
  "America/Mexico_City": "MX", "America/Cancun": "MX",
  // South America
  "America/Sao_Paulo": "BR", "America/Argentina/Buenos_Aires": "AR",
  "America/Santiago": "CL", "America/Bogota": "CO", "America/Lima": "PE",
  // Europe
  "Europe/London": "GB", "Europe/Dublin": "IE", "Europe/Paris": "FR",
  "Europe/Berlin": "DE", "Europe/Madrid": "ES", "Europe/Italy": "IT",
  "Europe/Rome": "IT", "Europe/Amsterdam": "NL", "Europe/Brussels": "BE",
  "Europe/Vienna": "AT", "Europe/Zurich": "CH", "Europe/Stockholm": "SE",
  "Europe/Oslo": "NO", "Europe/Copenhagen": "DK", "Europe/Helsinki": "FI",
  "Europe/Warsaw": "PL", "Europe/Prague": "CZ", "Europe/Budapest": "HU",
  "Europe/Lisbon": "PT", "Europe/Athens": "GR", "Europe/Istanbul": "TR",
  "Europe/Moscow": "RU", "Europe/Kiev": "UA", "Europe/Kyiv": "UA",
  // Asia
  "Asia/Tokyo": "JP", "Asia/Shanghai": "CN", "Asia/Hong_Kong": "HK",
  "Asia/Taipei": "TW", "Asia/Singapore": "SG", "Asia/Seoul": "KR",
  "Asia/Bangkok": "TH", "Asia/Jakarta": "ID", "Asia/Manila": "PH",
  "Asia/Kuala_Lumpur": "MY", "Asia/Ho_Chi_Minh": "VN", "Asia/Kolkata": "IN",
  "Asia/Karachi": "PK", "Asia/Dubai": "AE", "Asia/Tehran": "IR",
  "Asia/Jerusalem": "IL", "Asia/Riyadh": "SA",
  // Oceania
  "Australia/Sydney": "AU", "Australia/Melbourne": "AU", "Australia/Brisbane": "AU",
  "Australia/Perth": "AU", "Pacific/Auckland": "NZ",
  // Africa
  "Africa/Cairo": "EG", "Africa/Lagos": "NG", "Africa/Johannesburg": "ZA",
  "Africa/Nairobi": "KE", "Africa/Casablanca": "MA", "Africa/Accra": "GH",
};

/**
 * Maps timezone identifiers to region keys (country-region format). Only covers
 * regions distinguishable by timezone (e.g. US states, Canadian provinces).
 * Missing zones return undefined (region tier falls back to country tier).
 */
const TZ_TO_REGION: Record<string, string> = {
  "America/New_York": "US-NY", "America/Chicago": "US-IL", "America/Denver": "US-CO",
  "America/Los_Angeles": "US-CA", "America/Phoenix": "US-AZ", "America/Anchorage": "US-AK",
  "Pacific/Honolulu": "US-HI", "America/Toronto": "CA-ON", "America/Vancouver": "CA-BC",
  "America/Halifax": "CA-NS", "America/Edmonton": "CA-AB", "America/Winnipeg": "CA-MB",
  "Australia/Sydney": "AU-NSW", "Australia/Melbourne": "AU-VIC",
  "Australia/Brisbane": "AU-QLD", "Australia/Perth": "AU-WA",
};

// ---------------------------------------------------------------------------
// Locale → country code
// ---------------------------------------------------------------------------

/**
 * Parse a locale identifier (e.g. "en-US", "pt-BR", "ja_JP") into an ISO 3166-1
 * alpha-2 country code. Returns undefined if the locale doesn't carry a region.
 */
function localeToCountry(locale: string): string | undefined {
  // Match the region suffix: "en-US" → "US", "ja_JP" → "JP", "de-DE" → "DE"
  const match = locale.match(/[-_]([A-Z]{2})\b/);
  return match?.[1]?.toUpperCase();
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Derive geo keys from timezone and locale — no location permission needed.
 *
 * This is the spec's universal geography resolution path. It covers world +
 * country + region leaderboard tiers. The city tier requires the separate OS
 * coarse-location pipeline (CoreLocation / ACCESS_COARSE_LOCATION /
 * Windows.Devices.Geolocation), which is platform-specific and gated behind
 * the separate locationConsent tri-state.
 *
 * @param timezone IANA timezone identifier (e.g. Intl.DateTimeFormat().resolvedOptions().timeZone)
 * @param locale BCP 47 locale tag (e.g. Intl.DateTimeFormat().resolvedOptions().locale)
 */
export function deriveGeoKeys(timezone: string, locale: string): GeoKeys {
  const tzCountry = TZ_TO_COUNTRY[timezone];
  const tzRegion = TZ_TO_REGION[timezone];
  const localeCountry = localeToCountry(locale);

  // Prefer timezone-derived country (more reliable than locale for travelers),
  // fall back to locale-derived country.
  const countryCode = tzCountry ?? localeCountry;
  const regionKey = tzRegion;

  return {
    countryCode,
    regionKey,
    cityKey: undefined,
  };
}

// ---------------------------------------------------------------------------
// Geo key canonicalization + server-side normalization (shared spec)
// ---------------------------------------------------------------------------

/**
 * Server-side defense-in-depth: sanitize ANY geo key before it flows into a
 * Firestore document ID. This is a PURE, IDEMPOTENT strip — it removes only
 * doc-ID-unsafe characters (`/`, whitespace, control chars, and `_` which is
 * the `{window}_{tier}_{geoKey}` delimiter) and PRESERVES everything else
 * including case. It does NOT lowercase the key: country/region keys are
 * uppercase ("US", "US-CA") and clients read the exact doc ID verbatim, so
 * lowercasing server-side would break read/write path symmetry and silently
 * empty every board.
 *
 * The lowercasing + ASCII-fold is confined to slugifyCity (the citySlug
 * portion of canonicalizeCityKey), which both client and server run
 * identically. This function is the LAST line of defense against path
 * injection — one malformed key with `/` can crash the hourly aggregation
 * loop for everyone.
 *
 * Applied in callables before persisting AND defensively in the leaderboard
 * path builder.
 */
export function normalizeGeoKey(raw: string | undefined): string | undefined {
  if (!raw) return undefined;
  const sanitized = asciiFold(raw)
    .replace(/[^a-zA-Z0-9-]/g, "") // allowlist: keep only letters, digits, hyphens
    .replace(/-{2,}/g, "-") // collapse consecutive hyphens
    .replace(/^-+|-+$/g, ""); // strip leading/trailing hyphens
  return sanitized || undefined; // empty → undefined (omit the field)
}
/**
 * Canonicalize a raw city name into a stable, doc-ID-safe cityKey.
 *
 * CRITICAL: this canonicalization runs identically on every platform so that
 * users in the same physical city produce the SAME key regardless of which
 * geocoder (Apple CLGeocoder, Android Geocoder, Windows Geolocator, manual
 * picker) produced the raw name. Without this, city cohorts fragment across
 * platforms and never reach the k=10 threshold.
 *
 * Format: `{countryCode}-{regionCode}-{citySlug}`
 *   - countryCode: ISO 3166-1 alpha-2 (e.g. "US", "DE", "JP")
 *   - regionCode: ISO 3166-2 subdivision (e.g. "CA", "BY", "13")
 *   - citySlug: ASCII-folded + lowercased + non-alphanumeric → "-"
 *
 * Examples:
 *   "San Francisco", US, CA → "US-CA-san-francisco"
 *   "München", DE, BY       → "DE-BY-munchen"
 *   "São Paulo", BR, SP     → "BR-SP-sao-paulo"
 *
 * The result is safe for Firestore document IDs (no "/", no spaces, no "_"
 * colliding with the "{window}_{tier}_{geoKey}" leaderboard doc ID delimiter).
 *
 * @param cityName Raw city name from the geocoder (MUST be in a fixed locale —
 *                 request reverse-geocode with locale en_US_POSIX or equivalent
 *                 so "Milano" ≠ "Mailand" ≠ "Milan").
 * @param countryCode ISO 3166-1 alpha-2 country code.
 * @param regionCode ISO 3166-2 subdivision code WITHOUT the country prefix
 *                   (e.g. "CA" not "US-CA").
 */
export function canonicalizeCityKey(
  cityName: string,
  countryCode: string,
  regionCode: string,
): string {
  const country = countryCode.trim().toUpperCase();
  let region = regionCode.trim().toUpperCase();
  if (region.startsWith(`${country}-`)) {
    region = region.slice(country.length + 1);
  }
  const slug = slugifyCity(cityName);
  return `${country}-${region}-${slug}`;
}

/**
 * ASCII-fold a Unicode string: strips diacritics and non-ASCII so "München"
 * → "Munchen", "São Paulo" → "Sao Paulo", "České Budějovice" → "Ceske Budejovice".
 *
 * This MUST run identically on every platform. The implementation is the
 * standard NFD normalization + combining-mark strip. Swift/Android/C# ports
 * must use the equivalent: String.normalizingFormD + filter combining marks,
 * java.text.Normalizer.Form.NFD + \\p{M} strip, or
 * string.Normalize(NormalizationForm.FormD) + filtering.
 */
/**
 * Non-decomposable Unicode characters that NFD does NOT reduce to ASCII.
 * These MUST be replaced identically on every platform before NFD, or each
 * port produces a different cityKey for the same city → cohort fragmentation
 * → city tier silently dead below k=10.
 *
 * Port implementation notes:
 *   Swift:     Dictionary<Character, String> applied before .normalizingFormD
 *   Kotlin:    HashMap<Char, String> applied before Normalizer.normalize(NFD)
 *   C#:        Dictionary<char, string> applied before Normalize(FormD)
 *   TS/JS:     this Record applied before String.normalize("NFD")
 */
const NON_DECOMPOSABLE: Record<string, string> = {
  "\u00d8": "O", // Ø
  "\u00f8": "o", // ø (Tromsø)
  "\u0141": "L", // Ł
  "\u0142": "l", // ł (Łódź, Wrocław)
  "\u00d0": "D", // Ð (eth)
  "\u00f0": "d", // ð (Icelandic)
  "\u00de": "T", // Þ (thorn)
  "\u00fe": "t", // þ (Icelandic)
  "\u00df": "ss", // ß (German)
  "\u0130": "I", // İ (dotted I, Turkish — locale-insensitive)
  "\u0131": "i", // ı (dotless i, Turkish)
  "\u0110": "D", // Đ (d-stroke, Vietnamese)
  "\u0111": "d", // đ (d-stroke, Vietnamese)
  "\u014a": "N", // Ŋ (eng, Sámi)
  "\u014b": "n", // ŋ (eng, Sámi)
  "\u017d": "Z", // Ž
  "\u017e": "z", // ž
  "\u0160": "S", // Š
  "\u0161": "s", // š
  "\u015a": "S", // Ś
  "\u015b": "s", // ś
  "\u017b": "Z", // Ż
  "\u017c": "z", // ż
  "\u0106": "C", // Ć
  "\u0107": "c", // ć
  "\u010c": "C", // Č
  "\u010d": "c", // č
  "\u0158": "R", // Ř
  "\u0159": "r", // ř
  "\u016e": "U", // Ů
  "\u016f": "u", // ů
  "\u0147": "N", // Ň
  "\u0148": "n", // ň
  "\u010e": "D", // Ď
  "\u010f": "d", // ď
  "\u0164": "T", // Ť
  "\u0165": "t", // ť
};

export function asciiFold(input: string): string {
  // Step 1: replace non-decomposable characters BEFORE NFD.
  let out = input;
  for (const [from, to] of Object.entries(NON_DECOMPOSABLE)) {
    out = out.split(from).join(to);
  }
  // Step 2: NFD normalize + strip combining marks.
  return out
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
}

/**
 * Slugify a city name into a stable, doc-ID-safe token.
 *
 * Rules (identical on all platforms):
 *   1. ASCII-fold (strip diacritics)
 *   2. Lowercase
 *   3. Replace every run of [^a-z0-9]+ with a single "-"
 *   4. Strip leading/trailing "-"
 *   5. Truncate to 40 chars (keeps doc IDs reasonable)
 */
export function slugifyCity(cityName: string): string {
  return asciiFold(cityName)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40)
    .replace(/-+$/g, "");
}

/**
 * Populate a profile doc's geo keys from locale/timezone resolution.
 * Only sets keys that are consented at the corresponding tier.
 */
export function populateGeoKeys(
  profile: Partial<CommunityProfileDoc>,
  geo: GeoKeys,
  consentedTiers: { country: boolean; region: boolean; city: boolean },
): Partial<CommunityProfileDoc> {
  if (consentedTiers.country && geo.countryCode) {
    profile.countryCode = geo.countryCode;
  }
  if (consentedTiers.region && geo.regionKey) {
    profile.regionKey = geo.regionKey;
  }
  // City key is never populated from locale/timezone — requires OS location.
  return profile;
}
