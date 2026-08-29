/**
 * Reviewed first-party collector origins for official website builds.
 * Arbitrary https destinations are not allowed — a typo or takeover
 * host must not enter connect-src or the browser bundle.
 *
 * Production hosting may only use collect.burnbar.ai. Staging hosting may
 * only use collect-staging.burnbar.ai. Local / PR builds (no lane) accept
 * either reviewed host plus localhost.
 */

export const PRODUCTION_COLLECTOR_HOST = "collect.burnbar.ai";
export const STAGING_COLLECTOR_HOST = "collect-staging.burnbar.ai";

export const REVIEWED_COLLECTOR_HOSTS = Object.freeze([
  PRODUCTION_COLLECTOR_HOST,
  STAGING_COLLECTOR_HOST,
]);

export type CollectorLane = "production" | "staging";

export function resolveCollectorLane(raw?: string | null): CollectorLane | undefined {
  const trimmed = (raw ?? "").trim().toLowerCase();
  if (trimmed === "production" || trimmed === "staging") return trimmed;
  return undefined;
}

function isDefaultHttpsPort(url: URL): boolean {
  return url.port === "" || url.port === "443";
}

export function isReviewedCollectorOrigin(raw: string, lane?: CollectorLane): boolean {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return false;
  }
  if (url.username !== "" || url.password !== "") return false;
  if (lane === "production") {
    return (
      url.protocol === "https:" && url.hostname === PRODUCTION_COLLECTOR_HOST && isDefaultHttpsPort(url)
    );
  }
  if (lane === "staging") {
    return url.protocol === "https:" && url.hostname === STAGING_COLLECTOR_HOST && isDefaultHttpsPort(url);
  }
  if (/^(localhost|127\.0\.0\.1)$/.test(url.hostname)) {
    return url.protocol === "http:" || url.protocol === "https:";
  }
  if (url.protocol !== "https:") return false;
  if (!REVIEWED_COLLECTOR_HOSTS.includes(url.hostname)) return false;
  return isDefaultHttpsPort(url);
}
