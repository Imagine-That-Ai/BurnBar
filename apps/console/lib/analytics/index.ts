/**
 * Browser entry point for console analytics. Imported only from client
 * components ("use client"), so it runs client-side; the Amplitude chunk it
 * pulls is dynamically imported (its own bundle) and fetched only after opt-in.
 * With no `NEXT_PUBLIC_AMPLITUDE_API_KEY` the recorder stays dark by construction.
 *
 * This module mirrors website/src/lib/analytics/index.ts, adapted to Next.js:
 * the singleton wiring lives here; a React provider + hook
 * (lib/analytics/AnalyticsProvider.tsx) drives route/auth instrumentation.
 */
import { ConsentStore, type ConsentStorage } from "./consent";
import { Analytics, type AnalyticsProps } from "./recorder";
import { AmplitudeTransport } from "./amplitudeTransport";
import { EVENT, type AnalyticsEventName } from "./events";

const API_KEY = (process.env.NEXT_PUBLIC_AMPLITUDE_API_KEY as string | undefined) ?? "";
const SERVER_ZONE: "US" | "EU" =
  (process.env.NEXT_PUBLIC_AMPLITUDE_SERVER_ZONE as string | undefined) === "EU" ? "EU" : "US";
const APP_VERSION = (process.env.NEXT_PUBLIC_APP_VERSION as string | undefined) ?? "console";

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
    platform: "console", // cross-platform `platform` enum value for app.burnbar.ai
    app_version: APP_VERSION,
    surface: "console", // the console is a single bounded surface in the taxonomy
  }),
});

export { EVENT };
export type { AnalyticsEventName, AnalyticsProps };

/**
 * Bounded console route → route key. The console has a fixed, enumerated set of
 * routes; any unknown path collapses to "other" so a unique URL can never become
 * a unique (fingerprinting) property value. Used for `nav.route.changed`.
 */
const ROUTE_BY_PATH: Record<string, string> = {
  "/": "basin",
  "/inventory": "inventory",
  "/pensieve": "pensieve",
  "/escrow": "escrow",
  "/settings": "settings",
};

export function routeKeyForPath(pathname: string): string {
  const p = pathname.replace(/\/+$/, "") || "/";
  return ROUTE_BY_PATH[p] ?? "other";
}

const SESSION_KEY = "burnbar-console-analytics-session";

/**
 * Resume a consented session and emit session-start (once per tab) + the initial
 * page view. Safe to call on every load; dark until opt-in. The transport stays
 * unbuilt unless consent is granted and a key is present.
 */
export function boot(): void {
  analytics.startIfConsented();
  if (!analyticsConsent.isGranted) return;
  try {
    if (!sessionStorage.getItem(SESSION_KEY)) {
      sessionStorage.setItem(SESSION_KEY, "1");
      analytics.track(EVENT.appSessionStarted, { is_first_launch: false, cold_start: true });
    }
  } catch {
    /* sessionStorage blocked — skip the dedupe, still send the view below */
  }
  analytics.track(EVENT.screenViewed, { is_first_view: true });
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

/** Track a handled error without leaking the message — surface + bounded category only. */
export function trackHandledError(errorCategory: string): void {
  analytics.track(EVENT.errorHandled, { surface: "console", error_category: errorCategory });
}

/**
 * Identify the signed-in member by a SHA-256 hash of their Firebase uid — never
 * the raw uid, email, or name. No-op (and clears identity) when signed out.
 * Stored even while dark; only forwarded to the SDK after consent is granted.
 */
export async function identifyUser(uid: string | null | undefined): Promise<void> {
  if (!uid) {
    analytics.setUserId(undefined);
    return;
  }
  const hashed = await hashUid(uid);
  analytics.setUserId(hashed);
}

/** SHA-256(uid) → hex. WebCrypto is available in every supported browser. */
async function hashUid(uid: string): Promise<string> {
  try {
    const data = new TextEncoder().encode(`burnbar-console:${uid}`);
    const digest = await crypto.subtle.digest("SHA-256", data);
    return Array.from(new Uint8Array(digest))
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
  } catch {
    // Subtle crypto unavailable (ancient/insecure context) — fall back to no id
    // rather than ever forwarding a raw uid.
    return "anon";
  }
}
