import { ConsentSignal } from "./consent.js";
import { eventCategory, type AnalyticsEventName } from "./events.js";

/**
 * Property values are strings or booleans ONLY — raw numbers must be bucketed
 * first (see ./buckets), so an un-bucketed number is a compile error here. This
 * is the backend mirror of the website's `string | boolean` union and Swift's
 * `AnalyticsValue` (which has no numeric case).
 */
export type AnalyticsProps = Record<string, string | boolean>;

/**
 * One server-side analytics event, already resolved to its wire shape. The
 * transport serializes this into an Amplitude HTTP V2 event.
 *
 *  - `deviceId` is the anonymous per-install UUID PROPAGATED from the client
 *    (never a hardware id; the server mints nothing identity-bearing).
 *  - `userId` is set ONLY for authenticated server actions (a verified uid),
 *    matching the taxonomy's "no user_id unless authenticated sign-in".
 *  - `insertId` is the 7-day-window dedup key (so a webhook/callable retry that
 *    re-emits the same conversion is collapsed by Amplitude, not double-counted).
 */
export interface AnalyticsEnvelope {
  name: string;
  category: string;
  props: AnalyticsProps;
  deviceId: string;
  userId?: string;
  insertId: string;
  /** Event time in epoch millis (the conversion's real time, not send time). */
  timeMs: number;
}

/**
 * The transport seam. The real implementation (./amplitudeTransport) POSTs to
 * the Amplitude HTTP V2 API; tests inject a fake. The recorder never touches the
 * network directly, so the consent gate cannot be bypassed.
 */
export interface ServerAnalyticsTransport {
  readonly isStarted: boolean;
  start(apiKey: string): void;
  /** Enqueue/transmit one event. Implementations may batch; the recorder awaits. */
  track(event: AnalyticsEnvelope): Promise<void>;
  stop(): void;
}

/** Stable, collision-resistant insert_id for a conversion (idempotency key). */
type InsertIdFn = () => string;

interface ServerAnalyticsOptions {
  transport: ServerAnalyticsTransport;
  apiKey: string;
  /** Properties stamped onto every event (platform, app_version, …). */
  superProperties: () => AnalyticsProps;
  /** Defaults to crypto.randomUUID; injectable for deterministic tests. */
  insertId?: InsertIdFn;
  /** Defaults to Date.now; injectable for deterministic tests. */
  now?: () => number;
}

/**
 * Identity for a single conversion emit — the anonymous device id propagated
 * from the client, and (only for authenticated actions) the verified user id.
 */
export interface EmitIdentity {
  deviceId: string;
  userId?: string;
  /** A caller-supplied idempotency key (e.g. the Stripe event id or token hash).
   *  When present it IS the insert_id, so the same conversion dedupes across
   *  retries. When absent a random insert_id is minted. */
  dedupeKey?: string;
  /** The conversion's real event time; defaults to now. */
  timeMs?: number;
}

/**
 * The one wrapper every backend instrumentation call goes through. Ported from
 * `AgentLens/Services/Analytics/Analytics.swift` and
 * `website/src/lib/analytics/recorder.ts`.
 *
 * THE invariant (identical on every platform): a call is dropped unless consent
 * is `granted` AND a non-empty API key is present. No key → dark, by
 * construction. The transport is lazily started on the first permitted track.
 *
 * Unlike the long-lived client wrappers, the server takes the consent signal
 * PER CALL (propagated from the client), because a Function has no session to
 * remember. There is therefore no `consent.analytics.granted` emit here — that
 * one-time opt-in signal belongs to the client at the moment the user opts in;
 * the server only emits the high-value conversion it is authoritative for.
 */
export class ServerAnalytics {
  private readonly insertId: InsertIdFn;
  private readonly now: () => number;

  constructor(private readonly opts: ServerAnalyticsOptions) {
    this.insertId = opts.insertId ?? (() => globalThis.crypto.randomUUID());
    this.now = opts.now ?? (() => Date.now());
  }

  /** The single invariant: a non-empty key. Combined with the per-call consent
   *  gate below, this is "granted consent AND a non-empty key". No key → dark. */
  private get hasKey(): boolean {
    return this.opts.apiKey.length > 0;
  }

  private ensureStarted(): void {
    if (!this.opts.transport.isStarted) this.opts.transport.start(this.opts.apiKey);
  }

  /**
   * Record a taxonomy conversion. Silently dropped unless the PROPAGATED consent
   * is `granted` AND a key is configured. `unset`/`declined` and no-key are all
   * dark: the transport is never even started.
   *
   * @returns `true` if the event was handed to the transport, `false` if the
   *          consent/key gate dropped it (useful for tests and call-site asserts).
   */
  async track(
    event: AnalyticsEventName,
    consent: ConsentSignal,
    identity: EmitIdentity,
    props: AnalyticsProps = {},
  ): Promise<boolean> {
    // The gate — checked on EVERY call. granted consent AND a non-empty key.
    if (!consent.isGranted || !this.hasKey) return false;
    if (identity.deviceId.length === 0) return false; // anonymous id is mandatory

    this.ensureStarted();
    await this.opts.transport.track({
      name: event,
      category: eventCategory(event),
      props: { ...this.opts.superProperties(), ...props },
      deviceId: identity.deviceId,
      userId: identity.userId,
      insertId: identity.dedupeKey ?? this.insertId(),
      timeMs: identity.timeMs ?? this.now(),
    });
    return true;
  }
}
