/**
 * Backend entry point for the OPTIONAL, light server-side analytics stream.
 *
 * Mirrors `website/src/lib/analytics/index.ts`: it constructs the singleton
 * recorder + transport and exposes a tiny emit surface for the CONVERSION /
 * lifecycle events the client cannot reliably send. The consent gate is
 * per-request: a server event is emitted ONLY when the caller passes a verified
 * `granted` consent flag PROPAGATED from the client. Without that flag (or
 * without a configured key) the stream is dark — no SDK, no network.
 */
import { createHash } from "node:crypto";
import { ConsentSignal } from "./consent.js";
import { ServerAnalytics, type AnalyticsProps, type EmitIdentity } from "./recorder.js";
import { AmplitudeHttpTransport } from "./amplitudeTransport.js";
import { EVENT } from "./events.js";
import { amplitudeApiKey, amplitudeServerZone, backendAppVersion } from "./config.js";
import { bucketDurationSeconds } from "./buckets.js";

// `ConsentSignal` is re-exported because the wired call site constructs it from
// the propagated request field. `ANALYTICS_SECRETS` binds the Amplitude key to
// the handler so `.value()` resolves at request time.
export { ConsentSignal };
export { ANALYTICS_SECRETS } from "./config.js";

let singleton: ServerAnalytics | undefined;

/** Lazily build the recorder once per instance, reading the key at first use
 *  (so the Secret Manager value is resolved inside a secret-bound handler). */
function analytics(): ServerAnalytics {
  if (!singleton) {
    singleton = new ServerAnalytics({
      transport: new AmplitudeHttpTransport(amplitudeServerZone()),
      apiKey: amplitudeApiKey(),
      superProperties: () => ({
        platform: "backend",
        app_version: backendAppVersion(),
      }),
    });
  }
  return singleton;
}

/** Test seam: inject a fake recorder (real transport stubbed) without env plumbing. */
export function setServerAnalyticsForTest(instance: ServerAnalytics | undefined): void {
  singleton = instance;
}

// ---------------------------------------------------------------------------
// High-value server conversions (wired to ≤2 call sites; consent-gated).
// ---------------------------------------------------------------------------

/**
 * Sanitize the anonymous device id PROPAGATED from the client (untrusted input).
 * It must be an anonymous, non-identifying token — we accept only the UUID-ish
 * character set and a bounded length, and reject anything else to `""` (which
 * the recorder treats as "no anonymous id" → dark). Never trust it as PII-free
 * blindly; the character/length bound stops a free-text smuggle.
 */
export function boundedAnalyticsDeviceId(raw: unknown): string {
  if (typeof raw !== "string") return "";
  const trimmed = raw.trim();
  if (trimmed.length < 8 || trimmed.length > 64) return "";
  return /^[A-Za-z0-9_-]+$/.test(trimmed) ? trimmed : "";
}

/** Stable Amplitude account identity: SHA-256(Firebase uid), never the raw uid. */
function analyticsUserIdForUid(uid: string): string {
  return createHash("sha256").update(uid, "utf8").digest("hex");
}

/** Bounded enum of the entitlement families the server grants. */
type EntitlementFamily = "burnbar_pro" | "burnbar_pro_max" | "burnbar_ultra" | "hosted_quota_sync" | "other";

/** Bounded enum of the verified server source that granted the entitlement. */
type EntitlementSource = "stripe" | "google_play" | "app_store" | "grandfather" | "other";

/** Bounded enum of the platform the purchase originated on. */
type EntitlementPlatform = "ios" | "android" | "macos" | "web" | "other";

const KNOWN_FAMILIES = new Set<EntitlementFamily>([
  "burnbar_pro",
  "burnbar_pro_max",
  "burnbar_ultra",
  "hosted_quota_sync",
  "other",
]);

/** Collapse an arbitrary entitlement id to the bounded family enum (never a raw id). */
export function entitlementFamilyOf(entitlementID: string): EntitlementFamily {
  for (const family of KNOWN_FAMILIES) {
    if (family === entitlementID) return family;
  }
  return "other";
}

interface SubscriptionGrantParams {
  /** Verified, propagated consent decision from the client. */
  consent: ConsentSignal;
  /** Anonymous per-install device id propagated from the client. */
  deviceId: string;
  /** Authenticated server uid; hashed before it enters the Amplitude envelope. */
  userId: string;
  entitlementFamily: EntitlementFamily;
  source: EntitlementSource;
  platform: EntitlementPlatform;
  /** Whether the entitlement is active (e.g. expired-but-known grants are false). */
  isActive: boolean;
  /** Renewal/expiry seconds-from-now; bucketed before send (never the raw value). */
  expiresInSeconds?: number;
  /** Idempotency key (e.g. Stripe event id, purchase-token hash) → insert_id, so
   *  webhook/callable retries dedup inside Amplitude's 7-day window. */
  dedupeKey: string;
  /** The conversion's real event time (epoch millis); defaults to now. */
  timeMs?: number;
}

/**
 * Emit the backend conversion `subscription.entitlement.granted`. Dark unless
 * the propagated consent is `granted` and a key is configured.
 *
 * PII guard: NO emails, names, raw uids in properties, no amounts, no product
 * ids — only the bounded family/source/platform enums, an outcome boolean, and
 * a BUCKETED expiry duration. The authenticated `user_id` is set on the event
 * envelope (not a property), matching the taxonomy's identity rules.
 *
 * @returns whether the event was sent (false ⇒ gated/dark).
 */
export async function emitSubscriptionEntitlementGranted(params: SubscriptionGrantParams): Promise<boolean> {
  const props: AnalyticsProps = {
    entitlement_family: params.entitlementFamily,
    source: params.source,
    purchase_platform: params.platform,
    outcome: params.isActive ? "success" : "failure",
  };
  if (params.expiresInSeconds !== undefined && Number.isFinite(params.expiresInSeconds)) {
    props.expires_in_seconds_bucket = bucketDurationSeconds(params.expiresInSeconds);
  }

  const identity: EmitIdentity = {
    deviceId: params.deviceId,
    userId: analyticsUserIdForUid(params.userId),
    dedupeKey: params.dedupeKey,
    timeMs: params.timeMs,
  };

  return analytics().track(EVENT.subscriptionEntitlementGranted, params.consent, identity, props);
}

// Future server conversions (e.g. `auth.account.deleted` once a propagated
// consent flag exists at the account-deletion call site) follow the same shape:
// add a typed `emit<Conversion>()` here that builds bounded props + an
// `EmitIdentity` and calls `analytics().track(...)`. Keep one helper per
// conversion so the property contract stays explicit (no generic free-prop
// passthrough that could smuggle PII).
