/**
 * @fileoverview Build, persist, and serve the daily Intelligent Router
 *               Rundown.
 *
 * This is the production source-of-truth for the rundown the website
 * displays. The static website includes a build-time fallback fixture, but
 * the live page hydrates from this endpoint so the recommendations always
 * reflect what the daily Cloud Function actually saw.
 *
 * Flow:
 *
 *   1. Daily Cloud Function `refreshModelLandscapeBenchmarks` (scheduled.ts)
 *      writes sanitized snapshots + statuses to Firestore.
 *   2. `buildAndPersistRouterRundown(db)` reads those, computes the rundown,
 *      and writes `router_rundowns/{date}` + `router_rundowns/latest`.
 *   3. The public HTTPS function `latestRouterRundown` serves
 *      `router_rundowns/latest` with CORS + cache headers.
 *
 * Inputs are sanitized by `modelLandscape.ts` before they reach this module.
 * No API keys, cookies, bearer tokens, or raw auth material ever land in
 * snapshots or the rundown output.
 *
 * The types, parsing, and pure-signal helpers live in `routerRundownTypes.ts`;
 * the scoring/selection pipeline (`buildRouterRundown`) lives in
 * `routerRundownScoring.ts`. Both sets of symbols are re-exported below so every
 * external `import ... from "./routerRundown.js"` keeps resolving unchanged.
 */

import type { Firestore } from "firebase-admin/firestore";
import { onRequest } from "firebase-functions/v2/https";
import type { ModelBenchmarkSnapshotDoc, ModelBenchmarkSourceStatusDoc } from "./types.js";
import { isRecord, parseModelBenchmarkSnapshotDoc, parseModelBenchmarkSourceStatusDoc } from "./guards.js";
import { logError, logWarn } from "./logging.js";
import { setPublicJsonSecurityHeaders } from "./publicHttpSecurityHeaders.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";
import { parseModelMeta, parseRuntimeMeta, parsePreviousRundown } from "./routerRundownTypes.js";
import type { ModelMeta, RuntimeMeta } from "./routerRundownTypes.js";
import { buildRouterRundown } from "./routerRundownScoring.js";

export { FAVORITE_POLICY_VERSION } from "./routerRundownTypes.js";
export { buildRouterRundown } from "./routerRundownScoring.js";

// ───────────────────────────── persistence ─────────────────────────────────

/**
 * Load operator-maintained model + runtime metadata from Firestore. Falls
 * back to a built-in best-effort default catalog if the doc doesn't exist
 * yet (first deploy). The doc shape is:
 *
 *   router_rundown_catalog/current
 *     models: ModelMeta[]
 *     runtime: Record<modelID, RuntimeMeta>
 *
 * Operators bump this doc whenever the model landscape shifts.
 */
async function loadRundownCatalog(db: Firestore): Promise<{
  models: ModelMeta[];
  runtime: Record<string, RuntimeMeta>;
}> {
  const ref = db.doc("router_rundown_catalog/current");
  const snap = await ref.get();
  if (snap.exists) {
    const data = snap.data() ?? {};
    return {
      models: Array.isArray(data.models)
        ? data.models.map(parseModelMeta).filter((model): model is ModelMeta => model != null)
        : [],
      runtime: isRecord(data.runtime)
        ? Object.fromEntries(
            Object.entries(data.runtime).flatMap(([modelID, value]) => {
              const parsed = parseRuntimeMeta(value);
              return parsed ? [[modelID, parsed]] : [];
            }),
          )
        : {},
    };
  }
  return DEFAULT_CATALOG;
}

/**
 * Default catalog seeded on first deploy. Operators can update Firestore at
 * `router_rundown_catalog/current` without redeploying functions.
 */
const DEFAULT_CATALOG: { models: ModelMeta[]; runtime: Record<string, RuntimeMeta> } = {
  models: [],
  runtime: {},
};

export async function buildAndPersistRouterRundown(db: Firestore, now: Date = new Date()): Promise<void> {
  const date = now.toISOString().slice(0, 10);
  const generatedAt = now.toISOString();

  const [snapshotsSnap, statusesSnap, catalog, previousLatestSnap] = await Promise.all([
    db.collection("model_benchmark_snapshots").get(),
    db.collection("model_benchmark_source_status").get(),
    loadRundownCatalog(db),
    db.doc("router_rundowns/latest").get(),
  ]);

  const snapshots = snapshotsSnap.docs
    .map((d) => parseModelBenchmarkSnapshotDoc(d.data()))
    .filter((snapshot): snapshot is ModelBenchmarkSnapshotDoc => snapshot != null);
  const statuses = statusesSnap.docs
    .map((d) => parseModelBenchmarkSourceStatusDoc(d.data()))
    .filter((status): status is ModelBenchmarkSourceStatusDoc => status != null);
  const previousLatest = previousLatestSnap.exists ? previousLatestSnap.data() : undefined;
  const previousRundown =
    previousLatest && typeof previousLatest.date === "string" && previousLatest.date !== date
      ? parsePreviousRundown(previousLatest)
      : undefined;

  if (catalog.models.length === 0) {
    logWarn({
      event: "router_rundown.catalog_empty",
    });
  }

  const rundown = buildRouterRundown({
    date,
    generatedAt,
    models: catalog.models,
    snapshots,
    statuses,
    runtime: catalog.runtime,
    previousRundown,
  });

  const batch = db.batch();
  batch.set(db.doc(`router_rundowns/${date}`), rundown);
  batch.set(db.doc("router_rundowns/latest"), rundown);
  await batch.commit();
}

/**
 * Cost/abuse hardening for the public endpoint below.
 *
 * The raw cloudfunctions.net URL bypasses the Hosting CDN, so without an
 * in-process cache every GET is an invocation + a Firestore read. The cache is
 * keyed by rundown date ("latest" included) and bounded; `latest` and today's
 * doc are overwritten by every scheduled run so they get a short TTL, while
 * past dates are immutable after the day rolls over and can cache long.
 * 404s are negative-cached so missing-doc probes stop costing reads.
 */
const RUNDOWN_CACHE_MUTABLE_TTL_MS = 60_000;
const RUNDOWN_CACHE_IMMUTABLE_TTL_MS = 24 * 60 * 60 * 1000;
const RUNDOWN_CACHE_NEGATIVE_TTL_MS = 60_000;
const RUNDOWN_CACHE_MAX_ENTRIES = 64;

/** No rundown can exist before the feature shipped; earlier dates 404 without a read. */
const RUNDOWN_EARLIEST_DATE = "2025-01-01";

interface RundownCacheEntry {
  status: 200 | 404;
  body: unknown;
  expiresAtMillis: number;
}

const rundownResponseCache = new Map<string, RundownCacheEntry>();

/**
 * True when `candidate` (already regex-shaped YYYY-MM-DD) is a real calendar
 * date inside the window rundowns can exist in. The regex alone admits an
 * unbounded key space (e.g. 9999-99-99) that would defeat both the Hosting CDN
 * cache and this in-memory cache while still costing a Firestore read per key.
 */
function isPlausibleRundownDate(candidate: string, now: Date): boolean {
  const [year, month, day] = candidate.split("-").map(Number);
  const utc = new Date(Date.UTC(year, month - 1, day));
  if (utc.getUTCFullYear() !== year || utc.getUTCMonth() !== month - 1 || utc.getUTCDate() !== day) return false;
  if (candidate < RUNDOWN_EARLIEST_DATE) return false;
  // Allow one day ahead of server UTC "today" for clock skew; anything later
  // cannot have been written yet.
  const upperBound = new Date(now.getTime() + 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  return candidate <= upperBound;
}

function cachedRundownResponse(key: string, now: Date): RundownCacheEntry | undefined {
  const entry = rundownResponseCache.get(key);
  if (!entry) return undefined;
  if (now.getTime() >= entry.expiresAtMillis) {
    rundownResponseCache.delete(key);
    return undefined;
  }
  return entry;
}

function storeRundownResponse(key: string, status: 200 | 404, body: unknown, now: Date): void {
  // Delete-then-set keeps Map insertion order usable as an eviction queue.
  rundownResponseCache.delete(key);
  if (rundownResponseCache.size >= RUNDOWN_CACHE_MAX_ENTRIES) {
    const oldest = rundownResponseCache.keys().next().value;
    if (oldest !== undefined) rundownResponseCache.delete(oldest);
  }
  const today = now.toISOString().slice(0, 10);
  const ttlMillis =
    status !== 200
      ? RUNDOWN_CACHE_NEGATIVE_TTL_MS
      : key === "latest" || key === today
        ? RUNDOWN_CACHE_MUTABLE_TTL_MS
        : RUNDOWN_CACHE_IMMUTABLE_TTL_MS;
  rundownResponseCache.set(key, { status, body, expiresAtMillis: now.getTime() + ttlMillis });
}

/**
 * Public HTTPS endpoint serving the latest rundown as JSON.
 *
 * - GET /latestRouterRundown            → router_rundowns/latest
 * - GET /latestRouterRundown?date=YYYY-MM-DD → that day's rundown
 *
 * CORS open (this is public data by design). Cache 5 minutes.
 */
export const latestRouterRundown = onRequest(
  {
    region: FUNCTIONS_REGION,
    cors: true,
    // Unauthenticated endpoint: maxInstances is the only hard cap on
    // invocation spend if someone hammers the raw function URL.
    maxInstances: 10,
  },
  async (req, res) => {
    setPublicJsonSecurityHeaders(res);
    if (req.method !== "GET") {
      res.status(405).json({ error: "method_not_allowed" });
      return;
    }
    try {
      // Accept the date from either ?date=YYYY-MM-DD or the trailing path
      // segment (e.g. /api/router-rundown/2026-05-13).
      const pathSegment = (req.path ?? "").split("/").filter(Boolean).pop() ?? "";
      const candidate = typeof req.query.date === "string" ? req.query.date : pathSegment;
      const date = /^\d{4}-\d{2}-\d{2}$/.test(candidate) ? candidate : "latest";
      const now = new Date();
      if (date !== "latest" && !isPlausibleRundownDate(date, now)) {
        // Same response a missing doc would get, without the Firestore read.
        res.status(404).json({ error: "not_found", date });
        return;
      }
      const cached = cachedRundownResponse(date, now);
      if (cached) {
        if (cached.status === 200) res.set("Cache-Control", "public, max-age=300, s-maxage=300");
        res.status(cached.status).json(cached.body);
        return;
      }
      const { getFirestore } = await import("firebase-admin/firestore");
      const db = getFirestore();
      const docRef = db.doc(`router_rundowns/${date}`);
      const snap = await docRef.get();
      if (!snap.exists) {
        const body = { error: "not_found", date };
        storeRundownResponse(date, 404, body, now);
        res.status(404).json(body);
        return;
      }
      const body = snap.data();
      storeRundownResponse(date, 200, body, now);
      res.set("Cache-Control", "public, max-age=300, s-maxage=300");
      res.status(200).json(body);
    } catch (err) {
      logError({ event: "router_rundown.latest_failed", error: String(err) });
      res.status(500).json({ error: "internal" });
    }
  },
);
