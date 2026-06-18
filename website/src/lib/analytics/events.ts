/**
 * The canonical website event registry — the single source of website event
 * names. Tier 1 names are shared verbatim with every other platform (see
 * AgentLens/Services/Analytics/AnalyticsEvent.swift and
 * docs/analytics/event-taxonomy.md). Call sites reference `EVENT.*`, so an
 * off-taxonomy name can't be invented; the value is the wire name.
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

  // Website surfaces — marketing conversions
  downloadCtaClicked: "download.cta.clicked",
  pricingPlanViewed: "pricing.plan.viewed",
  pricingCtaClicked: "pricing.cta.clicked",
  navExternalClicked: "nav.external.clicked",
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

const SCREEN_VIEW = new Set<string>([
  EVENT.screenViewed,
  EVENT.navRouteChanged,
  EVENT.pricingPlanViewed,
]);

const CONVERSION_AUTH = new Set<string>([
  EVENT.authSignInCompleted,
  EVENT.authSignUpCompleted,
  EVENT.downloadCtaClicked,
  EVENT.pricingCtaClicked,
]);

const ERROR = new Set<string>([EVENT.errorHandled]);

/** Amplitude category metadata for an event (set as a property, never embedded in the name). */
export function eventCategory(name: AnalyticsEventName): AnalyticsCategory {
  if (LIFECYCLE.has(name)) return "lifecycle";
  if (SCREEN_VIEW.has(name)) return "screen_view";
  if (CONVERSION_AUTH.has(name)) return "conversion_auth";
  if (ERROR.has(name)) return "error";
  return "primary_action";
}
