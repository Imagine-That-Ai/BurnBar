import { EVENT, type AnalyticsEventName } from "./events";

/** Existing product events that also emit the CMO funnel alias. */
export const FUNNEL_ALIAS: Partial<Record<AnalyticsEventName, AnalyticsEventName>> = {
  [EVENT.screenViewed]: EVENT.pageViewed,
  [EVENT.appSessionStarted]: EVENT.appOpened,
  [EVENT.downloadCtaClicked]: EVENT.downloadClicked,
  [EVENT.pricingCtaClicked]: EVENT.ctaClicked,
  [EVENT.navExternalClicked]: EVENT.ctaClicked
};

/** Product event plus its CMO alias (if any). Consent still gates the send. */
export function eventsToEmit(event: AnalyticsEventName): AnalyticsEventName[] {
  const alias = FUNNEL_ALIAS[event];
  return alias ? [event, alias] : [event];
}
