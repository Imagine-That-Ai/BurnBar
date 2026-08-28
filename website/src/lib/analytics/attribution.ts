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
