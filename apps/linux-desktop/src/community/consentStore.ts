export type ConsentTriState = 'unset' | 'granted' | 'declined';

export type GeographyTier = 'world' | 'country' | 'region' | 'city';

export interface CommunityTierConsent {
  world: ConsentTriState;
  country: ConsentTriState;
  region: ConsentTriState;
  city: ConsentTriState;
}

export interface CommunityConsentState {
  l1Analytics: ConsentTriState;
  l2Rankings: ConsentTriState;
  l2Tiers: CommunityTierConsent;
  l3LookingGlass: ConsentTriState;
  locationConsent: ConsentTriState;
  /** Manual city label when OS location is unavailable (Linux). */
  manualCityInput?: string;
  updatedAt: string;
}

const STORAGE_KEY = 'openburnbar.linux.communityConsent.v1';

function defaultTiers(): CommunityTierConsent {
  return { world: 'unset', country: 'unset', region: 'unset', city: 'unset' };
}

export function defaultCommunityConsent(): CommunityConsentState {
  return {
    l1Analytics: 'unset',
    l2Rankings: 'unset',
    l2Tiers: defaultTiers(),
    l3LookingGlass: 'unset',
    locationConsent: 'unset',
    updatedAt: new Date(0).toISOString(),
  };
}

export function readCommunityConsent(): CommunityConsentState {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return defaultCommunityConsent();
    const parsed = JSON.parse(raw) as Partial<CommunityConsentState>;
    return {
      l1Analytics: parsed.l1Analytics ?? 'unset',
      l2Rankings: parsed.l2Rankings ?? 'unset',
      l2Tiers: { ...defaultTiers(), ...parsed.l2Tiers },
      l3LookingGlass: parsed.l3LookingGlass ?? 'unset',
      locationConsent: parsed.locationConsent ?? 'unset',
      manualCityInput: typeof parsed.manualCityInput === 'string' ? parsed.manualCityInput : '',
      updatedAt: parsed.updatedAt ?? new Date(0).toISOString(),
    };
  } catch {
    return defaultCommunityConsent();
  }
}

export function writeCommunityConsent(state: CommunityConsentState): void {
  try {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ ...state, updatedAt: new Date().toISOString() }),
    );
  } catch {
    // convenience only
  }
}

export function isConsentActive(value: ConsentTriState): boolean {
  return value === 'granted';
}

export function cycleTriState(value: ConsentTriState): ConsentTriState {
  if (value === 'unset') return 'granted';
  if (value === 'granted') return 'declined';
  return 'unset';
}

export function tierLabel(tier: GeographyTier): string {
  switch (tier) {
    case 'city':
      return 'City';
    case 'region':
      return 'Region';
    case 'country':
      return 'Country';
    default:
      return 'World';
  }
}