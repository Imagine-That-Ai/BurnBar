/**
 * @fileoverview Loader for the generated daily-rundown history.
 *
 * Astro consumes the JSON files written by `scripts/generate-rundown.mjs`
 * (and, in production, by the daily Cloud Function). This helper:
 *
 *   - imports every history JSON eagerly so getStaticPaths can enumerate
 *     dates at build time;
 *   - returns rundowns ordered newest-first;
 *   - provides convenience accessors for the latest rundown and any
 *     specific dated rundown.
 */

import type { RouterDailyRundown } from "./router-rundown";

// Note: import.meta.glob is an Astro/Vite built-in. The eager: true option
// inlines the JSON modules at build time so the array is statically known.
const historyModules = import.meta.glob<{ default: RouterDailyRundown }>(
  "./router-rundown-history/*.json",
  { eager: true }
);

function isDatedKey(key: string): boolean {
  return /\/\d{4}-\d{2}-\d{2}\.json$/.test(key);
}

export const ALL_RUNDOWNS: RouterDailyRundown[] = Object.entries(historyModules)
  .filter(([key]) => isDatedKey(key))
  .map(([, mod]) => mod.default)
  .sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0));

export const LATEST_RUNDOWN: RouterDailyRundown | undefined = ALL_RUNDOWNS[0];

export const ARCHIVE_DATES: string[] = ALL_RUNDOWNS.map((r) => r.date);

export function findRundownByDate(date: string): RouterDailyRundown | undefined {
  return ALL_RUNDOWNS.find((r) => r.date === date);
}
