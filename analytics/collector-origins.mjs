/**
 * Reviewed first-party collector origins for official website builds.
 * Arbitrary https destinations are not allowed — a typo or takeover
 * host must not enter connect-src or the browser bundle.
 */

export const REVIEWED_COLLECTOR_HOSTS = Object.freeze([
  "collect.burnbar.ai",
  "collect-staging.burnbar.ai",
]);

export function isReviewedCollectorOrigin(origin) {
  let url;
  try {
    url = new URL(origin);
  } catch {
    return false;
  }
  if (/^(localhost|127\.0\.0\.1)$/.test(url.hostname)) {
    return url.protocol === "http:" || url.protocol === "https:";
  }
  return url.protocol === "https:" && REVIEWED_COLLECTOR_HOSTS.includes(url.hostname);
}
