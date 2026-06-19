/**
 * The canonical backend event registry — the single source of backend
 * (`platform: backend`) event names. Tier 1 names are shared VERBATIM with every
 * other platform (see `AgentLens/Services/Analytics/AnalyticsEvent.swift`,
 * `website/src/lib/analytics/events.ts`, and `docs/analytics/event-taxonomy.md`).
 *
 * Call sites reference `EVENT.*` so an off-taxonomy name can't be invented; the
 * value is the wire name. New backend-specific (Tier 2) events follow
 * `surface.object.action` with snake_case props and are returned to the
 * orchestrator for central merge into the taxonomy.
 */
export const EVENT = {
  // Tier 1 — core cross-platform spine. REGISTERED, NOT YET WIRED (planned).
  // No backend call site emits these today, so they imply ZERO server coverage:
  //   - `auth.account.deleted` would belong on the server `deleteUserCloudData`
  //     path (erasure finalizes server-side), but that callable's payload is
  //     `Record<string, never>` — it propagates NO `granted` consent flag and NO
  //     anonymous `device_id`, and the recorder mandates both. Emitting it there
  //     would be an ambient server event, which the taxonomy forbids. It will be
  //     wired only once the client propagates those fields (see index.ts).
  //   - `error.handled` is the Tier 1 error spine; the server has no consent-
  //     propagating error surface to attach it to yet.
  // They stay in the registry (and the taxonomy) so the wire name is reserved
  // and parity-checked, but they are NOT instrumented. Do not read coverage in.
  authAccountDeleted: "auth.account.deleted",
  errorHandled: "error.handled",

  // Tier 2 — backend-specific server conversion. WIRED: emitted by the Google
  // Play / Stripe verification path (`callables/stripe.ts`). The client cannot
  // reliably send this: an entitlement is granted by the verified server path
  // (Stripe webhook / Play & App Store verification) only.
  subscriptionEntitlementGranted: "subscription.entitlement.granted",
} as const;

export type AnalyticsEventName = (typeof EVENT)[keyof typeof EVENT];

type AnalyticsCategory = "lifecycle" | "screen_view" | "primary_action" | "conversion_auth" | "error";

const LIFECYCLE = new Set<string>([]);

const SCREEN_VIEW = new Set<string>([]);

const CONVERSION_AUTH = new Set<string>([EVENT.authAccountDeleted, EVENT.subscriptionEntitlementGranted]);

const ERROR = new Set<string>([EVENT.errorHandled]);

/** Amplitude category metadata for an event (set as a property, never embedded in the name). */
export function eventCategory(name: AnalyticsEventName): AnalyticsCategory {
  if (LIFECYCLE.has(name)) return "lifecycle";
  if (SCREEN_VIEW.has(name)) return "screen_view";
  if (CONVERSION_AUTH.has(name)) return "conversion_auth";
  if (ERROR.has(name)) return "error";
  return "primary_action";
}
