import type { CommunityConsentDoc, CommunityTierConsent, ConsentTriState } from "./types";

const STORAGE_KEY = "openburnbar.console.communityConsent.v1";

function defaultTiers(): CommunityTierConsent {
  return { world: "unset", country: "unset", region: "unset", city: "unset" };
}

export function defaultCommunityConsent(): CommunityConsentDoc {
  return {
    l1Analytics: "unset",
    l2Rankings: "unset",
    l2Tiers: defaultTiers(),
    l3LookingGlass: "unset",
    locationConsent: "unset",
    manualCityInput: "",
    schemaVersion: 1,
    updatedAt: new Date(0).toISOString(),
  };
}

export function readLocalCommunityConsent(): CommunityConsentDoc {
  if (typeof window === "undefined") return defaultCommunityConsent();
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return defaultCommunityConsent();
    const parsed = JSON.parse(raw) as Partial<CommunityConsentDoc>;
    return {
      ...defaultCommunityConsent(),
      ...parsed,
      l2Tiers: { ...defaultTiers(), ...parsed.l2Tiers },
      manualCityInput: typeof parsed.manualCityInput === "string" ? parsed.manualCityInput : "",
    };
  } catch {
    return defaultCommunityConsent();
  }
}

export function writeLocalCommunityConsent(doc: CommunityConsentDoc): void {
  if (typeof window === "undefined") return;
  try {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ ...doc, updatedAt: new Date().toISOString() }),
    );
  } catch {
    // convenience only
  }
}

export function cycleTriState(value: ConsentTriState): ConsentTriState {
  if (value === "unset") return "granted";
  if (value === "granted") return "declined";
  return "unset";
}

export function isConsentActive(value: ConsentTriState): boolean {
  return value === "granted";
}