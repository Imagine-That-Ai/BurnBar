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
import { FUNNEL_PRODUCT, isBoundedSessionId } from "../../../../analytics/funnel-contract";
import {
  isReviewedCollectorOrigin,
  resolveCollectorLane
} from "../../../../analytics/collector-origins";

function collectorUrlFromEnv(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return "";
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch {
    throw new Error(`PUBLIC_ANALYTICS_COLLECTOR_URL must be an absolute URL, got: ${trimmed}`);
  }
  const local = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(url.origin);
  if (url.protocol !== "https:" && !local) {
    throw new Error(
      `PUBLIC_ANALYTICS_COLLECTOR_URL must be https (or http localhost / 127.0.0.1), got: ${trimmed}`
    );
  }
  const lane = resolveCollectorLane(import.meta.env.PUBLIC_ANALYTICS_COLLECTOR_LANE);
  if (!isReviewedCollectorOrigin(trimmed, lane)) {
    throw new Error(
      lane
        ? `PUBLIC_ANALYTICS_COLLECTOR_URL must be the ${lane} first-party collector, got: ${trimmed}`
        : `PUBLIC_ANALYTICS_COLLECTOR_URL must be a reviewed collector origin, got: ${trimmed}`
    );
  }
  return trimmed;
}

const COLLECTOR_URL = collectorUrlFromEnv(
  (import.meta.env.PUBLIC_ANALYTICS_COLLECTOR_URL as string | undefined) ?? ""
);
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
  storage: AttributionStorage = attributionSessionStorage(),
  consent: { hasDecided: boolean; isGranted: boolean } = analyticsConsent
): AnalyticsProps {
  if (consent.hasDecided && !consent.isGranted) {
    return {};
  }
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
    ...(analyticsConsent.isGranted && COLLECTOR_URL.length > 0
      ? { session_id: resolveSessionId(true) }
      : {}),
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
export const LAUNCHED_KEY = "burnbar-analytics-launched";
export const FIRST_VIEW_KEY = "burnbar-analytics-first-view";
export const EMAIL_PENDING_KEY = "burnbar-analytics-email-pending";
export const SESSION_ID_KEY = "burnbar-analytics-session-id";

type PendingEmailStorage = ConsentStorage & { removeItem?(key: string): void };

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

/** Write the once-per-tab marker only when the collector can send. */
export function claimSessionSpine(
  canSend: boolean,
  storage: {
    getItem(key: string): string | null;
    setItem(key: string, value: string): void;
  }
): boolean {
  if (!canSend) return false;
  return shouldEmitSessionSpine(storage);
}

/**
 * First browser launch is durable localStorage evidence, not a tab session.
 * Write the marker only when the collector can send. Revoke does not clear
 * it — a later grant is a returning session, not a first launch.
 */
export function claimFirstLaunch(
  canSend: boolean,
  storage: {
    getItem(key: string): string | null;
    setItem(key: string, value: string): void;
  }
): boolean {
  if (!canSend) return false;
  try {
    if (storage.getItem(LAUNCHED_KEY)) return false;
    storage.setItem(LAUNCHED_KEY, "1");
    return true;
  } catch {
    return true;
  }
}

/** Taxonomy-required lifecycle flags for `app.session.started`. */
export function sessionStartProps(
  canSend: boolean,
  storage: {
    getItem(key: string): string | null;
    setItem(key: string, value: string): void;
  } = safeStorage()
): { is_first_launch: boolean; cold_start: true } {
  return {
    is_first_launch: claimFirstLaunch(canSend, storage),
    cold_start: true
  };
}

/**
 * First screen view is per-tab session evidence. Write the marker only when
 * the collector can send. Revoke clears it with the session spine so a later
 * grant in the same tab is a new first view.
 */
export function claimFirstView(
  canSend: boolean,
  storage: {
    getItem(key: string): string | null;
    setItem(key: string, value: string): void;
  }
): boolean {
  if (!canSend) return false;
  try {
    if (storage.getItem(FIRST_VIEW_KEY)) return false;
    storage.setItem(FIRST_VIEW_KEY, "1");
    return true;
  } catch {
    return true;
  }
}

export function screenViewedProps(
  canSend: boolean,
  storage: {
    getItem(key: string): string | null;
    setItem(key: string, value: string): void;
  }
): { is_first_view: boolean } {
  return { is_first_view: claimFirstView(canSend, storage) };
}

export function clearSessionSpine(storage: { removeItem?(key: string): void }): void {
  try {
    storage.removeItem?.(SESSION_KEY);
    storage.removeItem?.(FIRST_VIEW_KEY);
    storage.removeItem?.(EMAIL_PENDING_KEY);
    storage.removeItem?.(SESSION_ID_KEY);
  } catch {
    /* private mode / quota */
  }
}

function sessionSpineStorage(): PendingEmailStorage {
  try {
    if (typeof sessionStorage !== "undefined") return sessionStorage;
  } catch {
    /* access can throw when storage is blocked */
  }
  return fallbackAttributionStorage;
}

/** Pending email captures live on the session store, not localStorage. */
export function pendingEmailStorage(): PendingEmailStorage {
  return sessionSpineStorage();
}

function newSessionId(): string {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  if (typeof crypto !== "undefined" && typeof crypto.getRandomValues === "function") {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }
  throw new Error("session_id requires a CSPRNG");
}

/**
 * One privacy-safe UUID per tab session. Mint only when the collector can
 * send. Revoke remints with the session spine.
 */
export function resolveSessionId(
  canSend: boolean,
  storage: {
    getItem(key: string): string | null;
    setItem(key: string, value: string): void;
  } = pendingEmailStorage(),
  createId: () => string = newSessionId
): string {
  if (!canSend) return "";
  try {
    const existing = storage.getItem(SESSION_ID_KEY)?.trim() ?? "";
    if (isBoundedSessionId(existing)) return existing;
  } catch {
    /* private mode / quota */
  }
  const id = createId();
  try {
    storage.setItem(SESSION_ID_KEY, id);
  } catch {
    /* ephemeral this page only */
  }
  return id;
}

/** Resume a consented session and emit session-start (once per tab) + the page
 *  view. Safe to call on every page load; dark until opt-in. Bounded
 *  attribution is remembered before a decision so a later grant on
 *  /download still carries the landing campaign. After decline or revoke
 *  the bag stays cleared — a campaign reload must not recapture. */
export function boot(): void {
  rememberAttribution();
  analytics.startIfConsented();
  if (!analytics.canSend) return;
  let emitSession = true;
  try {
    emitSession = claimSessionSpine(true, sessionStorage);
  } catch {
    emitSession = true;
  }
  if (emitSession) {
    trackEvent(EVENT.appSessionStarted, sessionStartProps(true, safeStorage()));
  }
  trackEvent(EVENT.screenViewed, screenViewedProps(true, sessionSpineStorage()));
  flushPendingEmailCapture(true, pendingEmailStorage(), safeStorage());
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
  clearSessionSpine(sessionSpineStorage());
}

export function revokeConsent(): void {
  analyticsConsent.revoke();
  analytics.consentDidChange();
  clearStoredAttribution(attributionSessionStorage());
  clearSessionSpine(sessionSpineStorage());
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

const FRESH_AUTH_WINDOW_MS = 60_000;

export type AuthAccountLike = {
  uid?: string | null;
  metadata?: {
    creationTime?: string | null;
    lastSignInTime?: string | null;
  } | null;
} | null;

/** True only when creation and last-sign-in parse and are within 60s. */
export function isFreshAuthAccount(user: AuthAccountLike): boolean {
  const created = Date.parse(user?.metadata?.creationTime ?? "");
  const lastSignIn = Date.parse(user?.metadata?.lastSignInTime ?? "");
  if (!Number.isFinite(created) || !Number.isFinite(lastSignIn)) return false;
  return Math.abs(lastSignIn - created) < FRESH_AUTH_WINDOW_MS;
}

const AUTH_CAPTURE_SOURCES = new Set(["google", "apple", "github", "facebook"]);

export function boundedAuthCaptureSource(source: string): string {
  return AUTH_CAPTURE_SOURCES.has(source) ? source : "unknown";
}

export function authCaptureSourceFromProviderId(providerId: string): string {
  const id = providerId.toLowerCase();
  if (id.includes("google")) return "google";
  if (id.includes("apple")) return "apple";
  if (id.includes("github")) return "github";
  if (id.includes("facebook")) return "facebook";
  return "unknown";
}

export const EMAIL_CAPTURED_KEY = "burnbar-analytics-email-captured";

/** FNV-1a 64-bit hex so localStorage never holds a raw Firebase uid or email. */
export function localAccountCaptureHash(accountId: string): string {
  let hash = 0xcbf29ce484222325n;
  const normalized = accountId.trim();
  for (let i = 0; i < normalized.length; i++) {
    hash ^= BigInt(normalized.charCodeAt(i));
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return hash.toString(16).padStart(16, "0");
}

function emailCaptureStorageKey(accountId: string): string {
  return `${EMAIL_CAPTURED_KEY}:${localAccountCaptureHash(accountId)}`;
}

export function hasRecordedEmailCapture(
  accountId: string,
  storage: ConsentStorage = safeStorage()
): boolean {
  const uid = accountId.trim();
  if (!uid) return false;
  try {
    return storage.getItem(emailCaptureStorageKey(uid)) === "1";
  } catch {
    return false;
  }
}

export function markEmailCaptured(
  accountId: string,
  storage: ConsentStorage = safeStorage()
): void {
  const uid = accountId.trim();
  if (!uid) return;
  try {
    storage.setItem(emailCaptureStorageKey(uid), "1");
  } catch {
    /* private mode / quota */
  }
}

function parsePendingEmailCapture(raw: string | null): { hash: string; source: string } | null {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as { hash?: unknown; source?: unknown };
    const hash = typeof parsed.hash === "string" ? parsed.hash : "";
    if (!/^[0-9a-f]{16}$/.test(hash)) return null;
    return { hash, source: boundedAuthCaptureSource(String(parsed.source ?? "")) };
  } catch {
    return null;
  }
}

/**
 * Privacy-safe pre-consent capture: hashed account id + bounded source only.
 * Never writes the durable captured marker and never stores an email.
 */
export function rememberPendingEmailCapture(
  accountId: string,
  source: string,
  storage: ConsentStorage = pendingEmailStorage(),
  capturedStorage: ConsentStorage = safeStorage()
): void {
  const uid = accountId.trim();
  if (!uid) return;
  if (hasRecordedEmailCapture(uid, capturedStorage)) return;
  try {
    storage.setItem(
      EMAIL_PENDING_KEY,
      JSON.stringify({
        hash: localAccountCaptureHash(uid),
        source: boundedAuthCaptureSource(source)
      })
    );
  } catch {
    /* private mode / quota */
  }
}

/** Emit a stored pre-consent capture after grant. No-op when dark or empty. */
export function flushPendingEmailCapture(
  canSend = analytics.canSend,
  pendingStorage: PendingEmailStorage = pendingEmailStorage(),
  capturedStorage: ConsentStorage = safeStorage(),
  emit: (source: string) => void = trackEmailCaptured
): boolean {
  if (!canSend) return false;
  let pending: { hash: string; source: string } | null = null;
  try {
    pending = parsePendingEmailCapture(pendingStorage.getItem(EMAIL_PENDING_KEY));
    pendingStorage.removeItem?.(EMAIL_PENDING_KEY);
  } catch {
    return false;
  }
  if (!pending) return false;
  const capturedKey = `${EMAIL_CAPTURED_KEY}:${pending.hash}`;
  try {
    if (capturedStorage.getItem(capturedKey) === "1") return false;
    capturedStorage.setItem(capturedKey, "1");
  } catch {
    /* still emit — the send is the user-visible outcome */
  }
  emit(pending.source);
  return true;
}

/** Credential-success path only — never restored onAuthStateChanged sessions. */
export function trackEmailCapturedIfNewAccount(
  user: AuthAccountLike,
  source = "unknown",
  storage: ConsentStorage = safeStorage(),
  canSend = analytics.canSend,
  pendingStorage: ConsentStorage = pendingEmailStorage()
): void {
  if (!isFreshAuthAccount(user)) return;
  const uid = typeof user?.uid === "string" ? user.uid.trim() : "";
  if (!uid) return;
  if (hasRecordedEmailCapture(uid, storage)) return;
  if (!canSend) {
    rememberPendingEmailCapture(uid, source, pendingStorage);
    return;
  }
  markEmailCaptured(uid, storage);
  trackEmailCaptured(boundedAuthCaptureSource(source));
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
