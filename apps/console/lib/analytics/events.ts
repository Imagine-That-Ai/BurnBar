/**
 * The canonical console event registry — the single source of console event
 * names. Tier 1 names are shared verbatim with every other platform (see
 * AgentLens/Services/Analytics/AnalyticsEvent.swift,
 * website/src/lib/analytics/events.ts, and docs/analytics/event-taxonomy.md).
 * Call sites reference `EVENT.*`, so an off-taxonomy name can't be invented; the
 * value is the wire name.
 *
 * Tier 2 console events follow `surface.object.action` (lowercase, dot-separated
 * segments, snake_case within a segment). They are registered with the taxonomy
 * (docs/analytics/event-taxonomy.md, "console" platform) before instrumentation.
 */
export const EVENT = {
  // Tier 1 — core cross-platform spine
  appSessionStarted: "app.session.started",
  screenViewed: "screen.viewed",
  navRouteChanged: "nav.route.changed",
  authSignInCompleted: "auth.sign_in.completed",
  authSignUpCompleted: "auth.sign_up.completed",
  authSignedOut: "auth.signed_out",
  settingsChanged: "settings.changed",
  errorHandled: "error.handled",
  consentAnalyticsGranted: "consent.analytics.granted",

  // Tier 2 — console surfaces (member Data & Privacy Control Center)
  // Inventory (surface: console)
  inventoryDomainExported: "inventory.domain.exported",
  inventoryDomainDeleted: "inventory.domain.deleted",
  // Pensieve knowledge sources (surface: console)
  pensieveRepoConnected: "pensieve.repo.connected",
  pensieveRepoDisconnected: "pensieve.repo.disconnected",
  pensieveResyncRequested: "pensieve.resync.requested",
  // Escrow / device trust (surface: console)
  escrowDeviceRegistered: "escrow.device.registered",
  escrowDeviceTrusted: "escrow.device.trusted",
  escrowDeviceFailed: "escrow.device.failed",
  // Passkey enrollment (surface: console)
  passkeyEnrollmentCompleted: "passkey.enrollment.completed",
  // Panic / revoke-all (surface: console)
  accountAccessRevoked: "account.access.revoked",
} as const;

export type AnalyticsEventName = (typeof EVENT)[keyof typeof EVENT];

export type AnalyticsCategory =
  | "lifecycle"
  | "screen_view"
  | "primary_action"
  | "conversion_auth"
  | "error";

const LIFECYCLE = new Set<string>([
  EVENT.appSessionStarted,
  EVENT.authSignedOut,
  EVENT.consentAnalyticsGranted,
]);

const SCREEN_VIEW = new Set<string>([EVENT.screenViewed, EVENT.navRouteChanged]);

const CONVERSION_AUTH = new Set<string>([
  EVENT.authSignInCompleted,
  EVENT.authSignUpCompleted,
  EVENT.escrowDeviceTrusted, // browser earns decrypt capability — a trust conversion
  EVENT.passkeyEnrollmentCompleted,
]);

const ERROR = new Set<string>([EVENT.errorHandled, EVENT.escrowDeviceFailed]);

/** Amplitude category metadata for an event (set as a property, never embedded in the name). */
export function eventCategory(name: AnalyticsEventName): AnalyticsCategory {
  if (LIFECYCLE.has(name)) return "lifecycle";
  if (SCREEN_VIEW.has(name)) return "screen_view";
  if (CONVERSION_AUTH.has(name)) return "conversion_auth";
  if (ERROR.has(name)) return "error";
  return "primary_action";
}
