/**
 * OpenBurnBar marketing-funnel event contract.
 *
 * Product analytics already use the `surface.object.action` taxonomy
 * (`screen.viewed`, `app.session.started`, `download.cta.clicked`, …).
 * This module is the small CMO acquisition contract. Wire names stay
 * taxonomy-legal (dotted) so governance tests keep their teeth.
 *
 * CMO logical name → wire name:
 *   page_viewed      → page.viewed
 *   app_opened       → app.opened          (opt-in only)
 *   cta_clicked      → cta.clicked
 *   download_clicked → download.clicked
 *   install_started  → install.started
 *   email_captured   → email.captured      (never a raw email)
 *
 * Consent is required. Default is off. product is always `burnbar`.
 * Never route these events to CubeLove (852537) or Hormiga (703455).
 */

export const FUNNEL_PRODUCT = "burnbar" as const;

/** CMO `surface` values. Distinct from the website page-surface enum. */
export const FUNNEL_SURFACES = [
  "macos",
  "ios",
  "android",
  "web",
  "extension",
] as const;

export type FunnelSurface = (typeof FUNNEL_SURFACES)[number];

/**
 * Amplitude project IDs for OpenBurnBar only.
 * Production 830583 · Dev 830581.
 */
export const AMPLITUDE_PROJECT = {
  production: 830583,
  development: 830581,
} as const;

export const FORBIDDEN_AMPLITUDE_PROJECTS = {
  cubelove: 852537,
  hormigaDefault: 703455,
  hormigaDesktop: 799824,
} as const;

export const FUNNEL_EVENT = {
  pageViewed: "page.viewed",
  appOpened: "app.opened",
  ctaClicked: "cta.clicked",
  downloadClicked: "download.clicked",
  installStarted: "install.started",
  emailCaptured: "email.captured",
} as const;

export type FunnelEventName = (typeof FUNNEL_EVENT)[keyof typeof FUNNEL_EVENT];

/** CMO brief names → taxonomy wire names. */
export const FUNNEL_CMO_ALIAS = {
  page_viewed: FUNNEL_EVENT.pageViewed,
  app_opened: FUNNEL_EVENT.appOpened,
  cta_clicked: FUNNEL_EVENT.ctaClicked,
  download_clicked: FUNNEL_EVENT.downloadClicked,
  install_started: FUNNEL_EVENT.installStarted,
  email_captured: FUNNEL_EVENT.emailCaptured,
} as const;

export const FUNNEL_EVENT_NAMES: readonly FunnelEventName[] = Object.values(FUNNEL_EVENT);

export const FUNNEL_ATTRIBUTION_KEYS = [
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_content",
  "utm_term",
  "click_id",
  "campaign",
  "slate_id",
  "post_id",
] as const;

export type FunnelAttributionKey = (typeof FUNNEL_ATTRIBUTION_KEYS)[number];

export type FunnelProps = {
  product: typeof FUNNEL_PRODUCT;
  surface: FunnelSurface;
  app_version?: string;
} & Partial<Record<FunnelAttributionKey, string>>;

/** Campaign / click-id tokens only — no spaces, emails, phones, or free text. */
export function isBoundedAttributionValue(value: string): boolean {
  if (!/^[A-Za-z0-9._:-]{1,64}$/.test(value)) return false;
  const digits = value.replace(/[._:-]/g, "");
  if (/\d{7,}/.test(digits)) return false;
  return true;
}

export function isFunnelEventName(name: string): name is FunnelEventName {
  return (FUNNEL_EVENT_NAMES as readonly string[]).includes(name);
}

export function isAllowedAmplitudeProject(projectId: number): boolean {
  return (
    projectId === AMPLITUDE_PROJECT.production ||
    projectId === AMPLITUDE_PROJECT.development
  );
}

export function isForbiddenAmplitudeProject(projectId: number): boolean {
  return (
    projectId === FORBIDDEN_AMPLITUDE_PROJECTS.cubelove ||
    projectId === FORBIDDEN_AMPLITUDE_PROJECTS.hormigaDefault ||
    projectId === FORBIDDEN_AMPLITUDE_PROJECTS.hormigaDesktop
  );
}

/** Resolve a project id for a build. Unknown / forbidden ids are rejected. */
export function resolveAmplitudeProjectId(
  raw: string | number | undefined | null,
): number | null {
  if (raw === undefined || raw === null || raw === "") return null;
  let id: number;
  if (typeof raw === "number") {
    if (!Number.isInteger(raw)) return null;
    id = raw;
  } else {
    const trimmed = String(raw).trim();
    if (!/^\d+$/.test(trimmed)) return null;
    id = Number(trimmed);
    if (!Number.isInteger(id)) return null;
  }
  if (isForbiddenAmplitudeProject(id)) return null;
  if (!isAllowedAmplitudeProject(id)) return null;
  return id;
}
