/**
 * Browser entry point for website analytics. Imported only from bundled
 * (non-inline) Astro `<script>` tags. The browser POSTs to a first-party
 * collector URL — it never receives an Amplitude API key. With no
 * `PUBLIC_ANALYTICS_COLLECTOR_URL` the recorder stays dark.
 */
import { ConsentStore, type ConsentStorage } from "./consent";
import { Analytics, type AnalyticsProps } from "./recorder";
import { FirstPartyCollectorTransport } from "./collectorTransport";
import { clearStoredAttribution, resolveAttribution, type AttributionStorage } from "./attribution";
import { EVENT, type AnalyticsEventName, type ArenaSignInProvider } from "./events";
import { eventsToEmit } from "./funnelAlias";
import { FUNNEL_PRODUCT } from "../../../../analytics/funnel-contract";

const COLLECTOR_URL =
  (import.meta.env.PUBLIC_ANALYTICS_COLLECTOR_URL as string | undefined)?.trim() ?? "";
const APP_VERSION = (import.meta.env.PUBLIC_APP_VERSION as string | undefined) ?? "web";

/** localStorage can be absent/blocked (private mode, SSR) — fall back to memory. */
function safeStorage(): ConsentStorage {
  try {
    if (typeof localStorage !== "undefined") return localStorage;
  } catch {
    /* access can throw when storage is blocked */
  }
  const m = new Map<string, string>();
  return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => void m.set(k, v) };
}

export const analyticsConsent = new ConsentStore(safeStorage());

function memoryAttributionStorage(): AttributionStorage {
  const m = new Map<string, string>();
  return {
    getItem: (k) => m.get(k) ?? null,
    setItem: (k, v) => void m.set(k, v),
    removeItem: (k) => void m.delete(k)
  };
}

const fallbackAttributionStorage = memoryAttributionStorage();

function attributionSessionStorage(): AttributionStorage {
  try {
    if (typeof sessionStorage !== "undefined") return sessionStorage;
  } catch {
    /* access can throw when storage is blocked */
  }
  return fallbackAttributionStorage;
}

export function rememberAttribution(
  search = typeof location !== "undefined" ? location.search : "",
  storage: AttributionStorage = attributionSessionStorage()
): AnalyticsProps {
  return resolveAttribution(search, storage);
}

export const analytics = new Analytics({
  consent: analyticsConsent,
  transport: new FirstPartyCollectorTransport(),
  collectorUrl: COLLECTOR_URL,
  superProperties: () => ({
    product: FUNNEL_PRODUCT,
    platform: "web",
    app_version: APP_VERSION,
    surface: typeof location !== "undefined" ? surfaceForPath(location.pathname) : "other",
    ...(typeof location !== "undefined" ? rememberAttribution(location.search) : {})
  })
});

export { EVENT, type ArenaSignInProvider };

/** Wire names that exist in the registry — guards declarative CTA tracking
 *  against off-taxonomy strings injected via data attributes. */
const KNOWN_EVENTS = new Set<string>(Object.values(EVENT));

/** Bounded marketing-route → surface key. Unknown paths collapse to "other"
 *  so a unique URL can never become a unique (fingerprinting) surface value. */
const SURFACE_BY_PATH: Record<string, string> = {
  "/": "home",
  "/download": "download",
  "/pricing": "pricing",
  "/trust": "trust",
  "/privacy": "privacy",
  "/security": "security",
  "/support": "support",
  "/mcp": "mcp",
  "/router": "router",
  "/control": "control",
  "/floo": "floo",
  "/link": "link"
};

export function surfaceForPath(pathname: string): string {
  const p = pathname.replace(/\/+$/, "") || "/";
  return SURFACE_BY_PATH[p] ?? "other";
}

const SESSION_KEY = "burnbar-analytics-session";

export function shouldEmitSessionSpine(storage: {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}): boolean {
  try {
    if (storage.getItem(SESSION_KEY)) return false;
    storage.setItem(SESSION_KEY, "1");
    return true;
  } catch {
    return true;
  }
}

/** Resume a consented session and emit session-start (once per tab) + the page
 *  view. Safe to call on every page load; dark until opt-in. Bounded
 *  attribution is remembered even before consent so a later grant on
 *  /download still carries the landing campaign. */
export function boot(): void {
  rememberAttribution();
  analytics.startIfConsented();
  if (!analyticsConsent.isGranted) return;
  let emitSession = true;
  try {
    emitSession = shouldEmitSessionSpine(sessionStorage);
  } catch {
    emitSession = true;
  }
  if (emitSession) trackEvent(EVENT.appSessionStarted);
  trackEvent(EVENT.screenViewed); // surface is carried by super-properties
}

export function grantConsent(): void {
  analyticsConsent.grant();
  analytics.consentDidChange();
  boot();
}

export function declineConsent(): void {
  analyticsConsent.decline();
  analytics.consentDidChange();
  clearStoredAttribution(attributionSessionStorage());
}

export function revokeConsent(): void {
  analyticsConsent.revoke();
  analytics.consentDidChange();
  clearStoredAttribution(attributionSessionStorage());
}

export function trackEvent(event: AnalyticsEventName, props?: AnalyticsProps): void {
  for (const name of eventsToEmit(event)) analytics.track(name, props);
}

/**
 * Email capture without a raw address. The only legal payload is that a
 * capture happened (`captured: true`) plus an optional bounded source.
 */
export function trackEmailCaptured(source = "unknown"): void {
  analytics.track(EVENT.emailCaptured, { captured: true, source: source.slice(0, 40) });
}

/**
 * Delegated, declarative CTA tracking. Any element with
 * `data-analytics-event="<wire.name>"` fires that event on click; each
 * `data-analytics-prop-<key>="<value>"` becomes a (bounded) string property.
 * No inline handlers — keeps the CSP free of per-element script hashes.
 */
export function installDelegatedTracking(): void {
  document.addEventListener(
    "click",
    (ev) => {
      const target = ev.target as Element | null;
      const el = target?.closest?.("[data-analytics-event]");
      if (!el) return;
      const name = el.getAttribute("data-analytics-event");
      if (!name || !KNOWN_EVENTS.has(name)) return;
      const props: AnalyticsProps = {};
      for (const attr of Array.from(el.attributes)) {
        if (attr.name.startsWith("data-analytics-prop-")) {
          const key = attr.name.slice("data-analytics-prop-".length).replace(/-/g, "_");
          props[key] = attr.value;
        }
      }
      trackEvent(name as AnalyticsEventName, props);
    },
    { capture: true }
  );
}
