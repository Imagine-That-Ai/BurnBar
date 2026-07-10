import type { JoinCommunityRequest } from "../api";
import type { CommunityConsentDoc, ConsentTriState } from "./types";
import { cityKeyFromManualCityInput } from "./geoCityKey";

function wireConsent(value: ConsentTriState): string {
  return value === "granted" ? "granted" : "declined";
}

export function deviceGeoKeys(): { timezone: string; locale: string } {
  if (typeof window === "undefined") {
    return { timezone: "UTC", locale: "en-US" };
  }
  const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const locale = navigator.language;
  return { timezone, locale };
}

export function buildJoinCommunityRequest(
  consent: CommunityConsentDoc,
  options?: {
    handle?: string;
    countryCode?: string;
    regionKey?: string;
    cityKey?: string;
  },
): JoinCommunityRequest {
  const { timezone, locale } = deviceGeoKeys();
  const payload: JoinCommunityRequest = {
    l1Analytics: wireConsent(consent.l1Analytics),
    l2Rankings: wireConsent(consent.l2Rankings),
    l2World: wireConsent(consent.l2Tiers.world),
    l2Country: wireConsent(consent.l2Tiers.country),
    l2Region: wireConsent(consent.l2Tiers.region),
    l2City: wireConsent(consent.l2Tiers.city),
    locationConsent: wireConsent(consent.locationConsent),
    l3LookingGlass: wireConsent(consent.l3LookingGlass),
    timezone,
    locale,
  };
  if (options?.handle?.trim()) payload.handle = options.handle.trim();
  if (options?.countryCode?.trim()) payload.countryCode = options.countryCode.trim();
  if (options?.regionKey?.trim()) payload.regionKey = options.regionKey.trim();
  const cityKey =
    options?.cityKey?.trim() ||
    (consent.l2Tiers.city === "granted" && consent.locationConsent === "granted"
      ? cityKeyFromManualCityInput(consent.manualCityInput ?? "", timezone, locale)
      : undefined);
  if (cityKey) payload.cityKey = cityKey;
  return payload;
}
