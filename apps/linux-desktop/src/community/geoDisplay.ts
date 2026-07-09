import { deriveGeoKeys } from './geoCityKey.js';
import type { CommunityConsentState, GeographyTier } from './consentStore.js';

const REGION_DISPLAY: Record<string, string> = {
  'US-NY': 'New York',
  'US-IL': 'Illinois',
  'US-CO': 'Colorado',
  'US-CA': 'California',
  'US-AZ': 'Arizona',
  'US-AK': 'Alaska',
  'US-HI': 'Hawaii',
  'CA-ON': 'Ontario',
  'CA-BC': 'British Columbia',
  'CA-NS': 'Nova Scotia',
  'CA-AB': 'Alberta',
  'CA-MB': 'Manitoba',
  'AU-NSW': 'New South Wales',
  'AU-VIC': 'Victoria',
  'AU-QLD': 'Queensland',
  'AU-WA': 'Western Australia',
};

const COUNTRY_DISPLAY: Record<string, string> = {
  US: 'United States',
  CA: 'Canada',
  GB: 'United Kingdom',
  DE: 'Germany',
  FR: 'France',
  AU: 'Australia',
  JP: 'Japan',
};

function deviceGeoKeys(): { timezone: string; locale: string } {
  try {
    const timezone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    const locale = navigator.language;
    return { timezone, locale };
  } catch {
    return { timezone: 'UTC', locale: 'en-US' };
  }
}

export function resolveGeoDisplayLabel(consent: CommunityConsentState, tier: GeographyTier): string {
  const manual = consent.manualCityInput?.trim();
  const { timezone, locale } = deviceGeoKeys();
  const geo = deriveGeoKeys(timezone, locale);

  switch (tier) {
    case 'city':
      if (manual) return manual;
      return 'City unavailable — add a manual city label';
    case 'region':
      if (geo.regionKey && REGION_DISPLAY[geo.regionKey]) return REGION_DISPLAY[geo.regionKey];
      if (geo.regionKey) return geo.regionKey;
      return 'Region unavailable';
    case 'country':
      if (geo.countryCode && COUNTRY_DISPLAY[geo.countryCode]) return COUNTRY_DISPLAY[geo.countryCode];
      if (geo.countryCode) return geo.countryCode;
      return 'Country unavailable';
    default:
      return 'Global';
  }
}