import {
  FUNNEL_ATTRIBUTION_KEYS,
  isBoundedAttributionValue,
  type FunnelAttributionKey
} from "../../../../analytics/funnel-contract";
import type { AnalyticsProps } from "./recorder";

const QUERY_ALIASES: Record<string, FunnelAttributionKey> = {
  utm_source: "utm_source",
  utm_medium: "utm_medium",
  utm_campaign: "utm_campaign",
  utm_content: "utm_content",
  utm_term: "utm_term",
  click_id: "click_id",
  gclid: "click_id",
  fbclid: "click_id",
  campaign: "campaign",
  slate_id: "slate_id",
  post_id: "post_id"
};

/** sessionStorage key for the funnel-session attribution bag. */
export const ATTRIBUTION_STORAGE_KEY = "burnbar-analytics-attribution";

export type AttributionStorage = {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem?(key: string): void;
};

/**
 * Bounded attribution from the current URL. Empty / oversized values are
 * omitted. Never includes the raw URL, referrer, or free text.
 */
export function attributionFromSearch(search: string): AnalyticsProps {
  const params = new URLSearchParams(search.startsWith("?") ? search.slice(1) : search);
  const out: AnalyticsProps = {};
  for (const [rawKey, rawValue] of params.entries()) {
    const key = QUERY_ALIASES[rawKey.toLowerCase()];
    if (!key) continue;
    const value = rawValue.trim().slice(0, 120);
    if (value.length === 0) continue;
    if (!isBoundedAttributionValue(value)) continue;
    if (!(FUNNEL_ATTRIBUTION_KEYS as readonly string[]).includes(key)) continue;
    out[key] = value;
  }
  return out;
}

function revalidateAttributionBag(raw: unknown): AnalyticsProps {
  if (!raw || typeof raw !== "object") return {};
  const out: AnalyticsProps = {};
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (typeof value !== "string") continue;
    if (!isBoundedAttributionValue(value)) continue;
    if (!(FUNNEL_ATTRIBUTION_KEYS as readonly string[]).includes(key)) continue;
    out[key] = value;
  }
  return out;
}

function readStoredAttribution(storage: AttributionStorage): AnalyticsProps {
  try {
    const raw = storage.getItem(ATTRIBUTION_STORAGE_KEY);
    if (!raw) return {};
    return revalidateAttributionBag(JSON.parse(raw) as unknown);
  } catch {
    return {};
  }
}

/**
 * Funnel-session attribution. A landing URL with bounded params replaces
 * the stored bag. An empty destination query (internal /download, /pricing)
 * returns the re-validated stored bag so CTA conversions keep the campaign.
 * Persist even before consent — values are already PII-rejected.
 */
export function resolveAttribution(search: string, storage: AttributionStorage): AnalyticsProps {
  const fromUrl = attributionFromSearch(search);
  if (Object.keys(fromUrl).length > 0) {
    try {
      storage.setItem(ATTRIBUTION_STORAGE_KEY, JSON.stringify(fromUrl));
    } catch {
      /* private mode / quota — still return the URL bag for this page */
    }
    return fromUrl;
  }
  return readStoredAttribution(storage);
}

export function clearStoredAttribution(storage: AttributionStorage): void {
  try {
    storage.removeItem?.(ATTRIBUTION_STORAGE_KEY);
  } catch {
    /* private mode / quota */
  }
}
