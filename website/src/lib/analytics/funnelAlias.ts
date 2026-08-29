import { EVENT, type AnalyticsEventName } from "./events";

/** Existing product events that also emit the CMO funnel alias. */
export const FUNNEL_ALIAS: Partial<Record<AnalyticsEventName, AnalyticsEventName>> = {
  [EVENT.screenViewed]: EVENT.pageViewed,
  [EVENT.appSessionStarted]: EVENT.appOpened,
  // Real artifact/store clicks use `download.clicked` and also emit the product event.
  // Header / mobile-nav `download.cta.clicked` is page navigation only — no funnel alias.
  [EVENT.downloadClicked]: EVENT.downloadCtaClicked,
  [EVENT.pricingCtaClicked]: EVENT.ctaClicked,
  [EVENT.navExternalClicked]: EVENT.ctaClicked
};

/** Product event plus its CMO alias (if any). Consent still gates the send. */
export function eventsToEmit(event: AnalyticsEventName): AnalyticsEventName[] {
  const alias = FUNNEL_ALIAS[event];
  return alias ? [event, alias] : [event];
}
