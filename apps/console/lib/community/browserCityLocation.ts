/**
 * Browser city resolution intentionally avoids third-party reverse geocoding.
 *
 * The web runtime can obtain coordinates only through `navigator.geolocation`,
 * but resolving those coordinates into a city would require sending raw lat/lon
 * to an external API. Community's privacy contract forbids that egress. Web and
 * Linux users can still provide a manual city label, which is canonicalized in
 * the join payload with timezone/locale-derived country and region keys.
 */
export async function resolveBrowserCityKey(): Promise<string | undefined> {
  return undefined;
}
