/**
 * Browser entry point for website analytics. Imported only from bundled
 * (non-inline) Astro `<script>` tags, so it runs client-side and the Amplitude
 * chunk it pulls is served from `'self'` (CSP-clean) and fetched only after
 * opt-in. With no `PUBLIC_AMPLITUDE_API_KEY` the recorder stays dark.
 */
import { ConsentStore, type ConsentStorage } from "./consent";
import { Analytics, type AnalyticsProps } from "./recorder";
import { AmplitudeTransport } from "./amplitudeTransport";
import { EVENT, type AnalyticsEventName, type ArenaSignInProvider } from "./events";

const API_KEY = (import.meta.env.PUBLIC_AMPLITUDE_API_KEY as string | undefined) ?? "";
const SERVER_ZONE: "US" | "EU" =
  (import.meta.env.PUBLIC_AMPLITUDE_SERVER_ZONE as string | undefined) === "EU" ? "EU" : "US";
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

export const analytics = new Analytics({
  consent: analyticsConsent,
  transport: new AmplitudeTransport(SERVER_ZONE),
  apiKey: API_KEY,
  superProperties: () => ({
    platform: "web",
    app_version: APP_VERSION,
    surface: typeof location !== "undefined" ? surfaceForPath(location.pathname) : "other"
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

/** Resume a consented session and emit session-start (once per tab) + the page
 *  view. Safe to call on every page load; dark until opt-in. */
export function boot(): void {
  analytics.startIfConsented();
  if (!analyticsConsent.isGranted) return;
  try {
    if (!sessionStorage.getItem(SESSION_KEY)) {
      sessionStorage.setItem(SESSION_KEY, "1");
      analytics.track(EVENT.appSessionStarted);
    }
  } catch {
    /* sessionStorage blocked — skip the dedupe, still send the view below */
  }
  analytics.track(EVENT.screenViewed); // surface is carried by super-properties
}

export function grantConsent(): void {
  analyticsConsent.grant();
  analytics.consentDidChange();
  boot();
}

export function declineConsent(): void {
  analyticsConsent.decline();
  analytics.consentDidChange();
}

export function revokeConsent(): void {
  analyticsConsent.revoke();
  analytics.consentDidChange();
}

export function trackEvent(event: AnalyticsEventName, props?: AnalyticsProps): void {
  analytics.track(event, props);
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
      analytics.track(name as AnalyticsEventName, props);
    },
    { capture: true }
  );
}
