/**
 * Tri-state analytics consent for the BACKEND stream, ported from
 * `AgentLens/Services/Analytics/AnalyticsConsentStore.swift` and
 * `website/src/lib/analytics/consent.ts`.
 *
 * The server holds NO persisted consent of its own — it is stateless across
 * invocations and a Cloud Function has no "session" to remember. Instead the
 * consent decision is PROPAGATED per request from the client that already owns
 * the tri-state store. The gate's job is to interpret that propagated signal
 * exactly like the client stores would:
 *
 *   - `granted`  → the only state that permits egress.
 *   - `declined` / `unset` → identical dark states (no SDK, no network).
 *   - any malformed/absent value collapses to `unset` (dark) — fail closed.
 *
 * NEVER emit an ambient/automatic server event for a session without a
 * propagated `granted` signal. Revoke is `declined`, never back to `unset`,
 * but the server only ever sees a point-in-time signal so it just reads it.
 */
type ConsentState = "unset" | "granted" | "declined";

/** Coerce an untrusted propagated value into the tri-state. Fail closed: any
 *  value that is not literally `"granted"` or `"declined"` is `unset` (dark). */
function parseConsentState(raw: unknown): ConsentState {
  return raw === "granted" || raw === "declined" ? raw : "unset";
}

/**
 * The per-request consent gate. Mirrors `ConsentStore` — `isGranted` is the
 * single boolean every send is checked against, and `hasDecided` distinguishes
 * an answered prompt from the default dark `unset`.
 */
export class ConsentSignal {
  readonly state: ConsentState;

  constructor(raw: unknown) {
    this.state = parseConsentState(raw);
  }

  /** The single gate the recorder reads on every call. */
  get isGranted(): boolean {
    return this.state === "granted";
  }

  /** True once the user has answered the prompt either way (granted or declined). */
  get hasDecided(): boolean {
    return this.state !== "unset";
  }
}
