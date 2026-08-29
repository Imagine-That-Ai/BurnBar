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

  // CMO acquisition funnel (taxonomy-legal aliases of page_viewed / app_opened / …)
  pageViewed: "page.viewed",
  appOpened: "app.opened",
  ctaClicked: "cta.clicked",
  downloadClicked: "download.clicked",
  installStarted: "install.started",
  emailCaptured: "email.captured",

  // BurnBench Arena — the vote page uses the "neural" skin.
  // Exposure is emitted once per session; `played` reports that a voter
  // actually used an artifact (the engagement half of the judgement), and the
  // vote event carries variant + choice + rubric depth, so engagement,
  // conversion, and optional-rubric uptake all compare across the single look.
  // Properties stay a bounded vocabulary — `rubric` is a depth bucket
  // (none/partial/full), never the per-dimension verdicts themselves.
  arenaVariantExposed: "arena.variant.exposed",
  arenaArtifactPlayed: "arena.artifact.played",
  arenaVoteRecorded: "arena.vote.recorded",
  arenaAuthGateShown: "arena.auth.gate_shown",
  arenaSignInCompleted: "arena.sign_in.completed"
} as const;

export type AnalyticsEventName = (typeof EVENT)[keyof typeof EVENT];
export const ARENA_SIGN_IN_PROVIDERS = ["google", "apple", "github", "facebook"] as const;
export type ArenaSignInProvider = (typeof ARENA_SIGN_IN_PROVIDERS)[number];

export type AnalyticsCategory =
  | "lifecycle"
  | "screen_view"
  | "primary_action"
  | "conversion_auth"
  | "error";

const LIFECYCLE = new Set<string>([
  EVENT.appSessionStarted,
  EVENT.appOpened,
  EVENT.installStarted,
  EVENT.authSignedOut,
  EVENT.consentAnalyticsGranted
]);

const SCREEN_VIEW = new Set<string>([
  EVENT.screenViewed,
  EVENT.pageViewed,
  EVENT.navRouteChanged,
  EVENT.pricingPlanViewed
]);

const CONVERSION_AUTH = new Set<string>([
  EVENT.authSignInCompleted,
  EVENT.authSignUpCompleted,
  EVENT.downloadCtaClicked,
  EVENT.downloadClicked,
  EVENT.ctaClicked,
  EVENT.pricingCtaClicked,
  EVENT.emailCaptured
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
