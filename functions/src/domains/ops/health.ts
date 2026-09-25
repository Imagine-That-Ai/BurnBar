/**
 * Health check endpoint for OpenBurnBar Cloud Functions.
 *
 * Exposes:
 *   GET /healthCheck  → 200 { status: "ok", timestamp, version, uptime_ms, checks }
 *   GET /healthLive   → 200 { status: "alive" } — liveness probe for load balancers
 *   GET /healthReady  → 200/503 — readiness probe; 503 if Firestore unreachable.
 *                       Body carries sentry: { enabled, environment } (H13) so
 *                       the post-deploy gate can verify crash reporting is live.
 *
 * All three are public (no auth) and safe to hit from monitoring tools.
 * Usage: curl https://us-central1-<project>.cloudfunctions.net/healthCheck
 *
 * LIVENESS CONTRACT (Stream D): healthLive is the ONLY endpoint load balancers
 * and GCP uptime checks may use for "is this instance up". It is deliberately
 * NOT product-rate-limited and performs NO Firestore I/O, so it answers 200
 * whenever the process is alive — under monitor bursts, under abusive load, and
 * even during a Firestore outage. A 429 or 500 from any other endpoint (or from
 * the Firestore-backed limiter itself) must NEVER be interpreted as DOWN; point
 * liveness at healthLive and treat 429 elsewhere as "back off and retry".
 * healthReady/healthCheck keep their per-IP rate limits because each call costs
 * Firestore reads; their 429s carry a Retry-After hint.
 *
 * RUNTIME COORDINATES DECISION (Stream D): the `domainCore.runtime` block
 * (K_SERVICE/K_REVISION/K_CONFIGURATION/FUNCTION_TARGET) stays public. The
 * post-deploy gate (scripts/ci/post-deploy-health-gate.sh) requires these
 * coordinates to prove the probed instance is the just-deployed revision, and
 * the values are low-sensitivity — the service name is derivable from the
 * public function URL and the revision is an opaque Cloud Run suffix carrying
 * no tenant data, credentials, or version fingerprint beyond `version`.
 */

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { onRequest } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";
import { logInfo, logError, wrapRequestHandler } from "@openburnbar/functions-shared/logging.js";
import { FUNCTIONS_REGION } from "@openburnbar/functions-shared/runtimeOptions.js";
import { sourceMetadata } from "../../sourceMetadata.js";
import { domainCoreDeploymentIdentity } from "@openburnbar/functions-shared/domainCoreBuildProfile.js";
import { loadedDomainCorePricingIdentity } from "@openburnbar/functions-shared/domainCorePricing.js";
import { sentryStatus } from "@openburnbar/functions-shared/sentry.js";
import { setPublicJsonSecurityHeaders } from "@openburnbar/functions-shared/publicHttpSecurityHeaders.js";
import {
  checkPublicHttpEndpointRateLimit,
  clientIpFromHttpRequest,
  isPublicRateLimitExceeded,
} from "@openburnbar/functions-shared/callables/publicRateLimit.js";

const FUNCTION_VERSION = process.env.FUNCTION_VERSION ?? "unknown";
const MANIFEST_FILE_NAME = "domain-core-runtime-artifact-manifest.json";
// The release pipeline installs the manifest at the codebase lib root while
// this module lives under lib/domains/ops. Search upward (bounded) so the
// lookup survives domains nesting; absent in dev, where null is the honest
// signal (see domainCoreDeploymentIdentityForHealth).
function resolveManifestPath(): string {
  let dir = __dirname;
  for (let depth = 0; depth < 5; depth += 1) {
    const candidate = resolve(dir, MANIFEST_FILE_NAME);
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return resolve(__dirname, MANIFEST_FILE_NAME);
}
const manifestPath = resolveManifestPath();

/**
 * Build the domain-core deployment identity served by the health endpoints.
 *
 * This is computed lazily on the first request (and memoized) rather than at
 * module top level so that importing this module — and therefore building or
 * booting the Functions emulator — never fails before the release-only runtime
 * artifact manifest or the domain-core WASM exists. Source/dev builds and
 * fresh checkouts have neither artifact; only the production deploy pipeline
 * installs both into `functions/lib`.
 *
 * When an artifact is absent the corresponding field reports an explicit
 * `null` (never a fabricated digest or identity). A production release deploy
 * always has both artifacts present, so the served digests are real and the
 * post-deploy health gate fails closed on any absence or mismatch — there is
 * no silent fake fallback path.
 */
let cachedDomainCoreDeploymentIdentity: Record<string, unknown> | undefined;

function domainCoreDeploymentIdentityForHealth(): Record<string, unknown> {
  if (cachedDomainCoreDeploymentIdentity) return cachedDomainCoreDeploymentIdentity;

  const identity: Record<string, unknown> = {
    ...(domainCoreDeploymentIdentity() ?? {}),
    runtime: {
      service: process.env.K_SERVICE ?? null,
      revision: process.env.K_REVISION ?? null,
      configuration: process.env.K_CONFIGURATION ?? null,
      functionTarget: process.env.FUNCTION_TARGET ?? null,
    },
  };

  // loadedCore: real intrinsic/byte identity of the loaded domain-core WASM.
  // Absent (null) when the WASM package is unavailable — e.g. a source build
  // without the vendored package linked. Never fabricated.
  try {
    identity.loadedCore = loadedDomainCorePricingIdentity();
  } catch {
    identity.loadedCore = null;
  }

  // artifactManifest: sha256 of the immutable runtime artifact manifest
  // installed by the release pipeline. Absent (null) when the manifest file
  // does not exist — e.g. dev imports/builds/emulators before a release. The
  // post-deploy gate compares this to the expected digest and fails closed on
  // null; no fabricated hash is ever reported.
  if (existsSync(manifestPath)) {
    const manifestBytes = readFileSync(manifestPath);
    identity.artifactManifest = {
      fileName: MANIFEST_FILE_NAME,
      sha256: createHash("sha256").update(manifestBytes).digest("hex"),
    };
  } else {
    identity.artifactManifest = null;
  }

  cachedDomainCoreDeploymentIdentity = identity;
  return identity;
}

/** Seconds monitors should wait before retrying a rate-limited health probe. */
const HEALTH_RATE_LIMIT_RETRY_AFTER_SECONDS = "60";

type DependencyCheck = "ok" | "error";

interface FirestoreReadiness {
  latencyMs: number;
  firestore: DependencyCheck;
  firestoreTransaction: DependencyCheck;
}

/**
 * Probe Firestore with a hard timeout shared across both sub-checks.
 *
 *   - firestore: single-doc read (the historical readiness signal).
 *   - firestoreTransaction: read-only transaction over the same doc. This
 *     exercises the transaction Begin/Commit RPC surface that every Firestore
 *     write depends on, without mutating data — a cheap write-path-adjacent
 *     signal. A backend that serves plain reads but rejects transactions (the
 *     product rate limiter itself runs in a transaction) is not healthy.
 *
 * Never throws for backend failures: each sub-check reports "ok"/"error"
 * independently so the response `checks` object stays honest about partial
 * degradation. Only a client-construction failure (getFirestore throwing
 * before any RPC) propagates to the caller, which reports all-error.
 * Uses clearTimeout to avoid timer leaks in warm container instances.
 *
 * Coverage note — what readiness still does NOT prove:
 *   - actual mutation writes (deliberately unprobed: a write per probe would
 *     cost quota on every LB tick and contend on a single doc);
 *   - Firebase Auth, FCM/APNs delivery, Sentry ingest, or provider APIs;
 *   - regional failover (this probes the instance's own region only).
 */
async function probeFirestoreReadiness(timeoutMs = 3000): Promise<FirestoreReadiness> {
  const startMs = Date.now();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let timedOut = false;

  const timeoutPromise = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      timedOut = true;
      reject(new Error(`Firestore probe timed out after ${timeoutMs}ms`));
    }, timeoutMs);
  });

  let firestore: DependencyCheck = "error";
  let firestoreTransaction: DependencyCheck = "error";
  try {
    const db = getFirestore();
    const probeRef = db.collection("_health").doc("probe");
    try {
      await Promise.race([probeRef.get(), timeoutPromise]);
      firestore = "ok";
    } catch {
      // Stays "error" — reported honestly in `checks`, not thrown.
    }
    if (!timedOut) {
      try {
        await Promise.race([
          db.runTransaction(async (tx) => {
            await tx.get(probeRef);
          }),
          timeoutPromise,
        ]);
        firestoreTransaction = "ok";
      } catch {
        // Stays "error" — reported honestly in `checks`, not thrown.
      }
    }
    return { latencyMs: Date.now() - startMs, firestore, firestoreTransaction };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Domain-core dependency state for readiness.
 *
 * Returns "loaded" when the pricing WASM identity is present, "unavailable"
 * otherwise. It gates the 200/503 verdict ONLY when the deployment serves in
 * `rust` pricing mode (production), where a missing core breaks pricing. In
 * every other mode the TypeScript fallback serves traffic, so the check is
 * informational — dev/source builds without the vendored WASM stay ready.
 */
function domainCoreReadiness(identity: Record<string, unknown>): {
  check: "loaded" | "unavailable";
  gatesVerdict: boolean;
} {
  const check = identity.loadedCore == null ? "unavailable" : "loaded";
  return { check, gatesVerdict: identity.pricingMode === "rust" };
}

/**
 * Liveness probe — returns 200 if the function process is alive.
 *
 * Deliberately exempt from the product rate limiter AND from Firestore: the
 * limiter is Firestore-backed, so limiting liveness would 429 under monitor
 * bursts and 500 during a Firestore outage — both misread as DOWN by load
 * balancers. This handler performs no I/O (static identity + timestamps), so
 * per-request cost is ~zero and platform maxInstances/concurrency bounds abuse.
 *
 * Registry status: "healthLive" was removed from
 * RATE_LIMITED_PUBLIC_HTTP_ENDPOINTS and added to DOCUMENTED_EXEMPTIONS in
 * publicEndpointRateLimitInventory.test.ts, citing this contract — the
 * inventory stays green and the declarations stay true.
 */
export const healthLive = onRequest(
  { region: FUNCTIONS_REGION, cors: false, invoker: "public" },
  wrapRequestHandler("healthLive", async (_req, res) => {
    setPublicJsonSecurityHeaders(res);
    res.status(200).json({
      status: "alive",
      timestamp: new Date().toISOString(),
      domainCore: domainCoreDeploymentIdentityForHealth(),
      ...sourceMetadata(),
    });
  }),
);

/**
 * Readiness probe — verifies dependencies respond within 3 seconds.
 * Returns 200 when ready, 503 when degraded.
 * A 429 here means "monitor, back off and retry" — never DOWN (see liveness
 * contract above); it carries a Retry-After hint for well-behaved pollers.
 */
export const healthReady = onRequest(
  { region: FUNCTIONS_REGION, cors: false, invoker: "public" },
  wrapRequestHandler("healthReady", async (req, res) => {
    setPublicJsonSecurityHeaders(res);
    try {
      await checkPublicHttpEndpointRateLimit("healthReady", clientIpFromHttpRequest(req));
    } catch (err) {
      if (isPublicRateLimitExceeded(err)) {
        res.setHeader("Retry-After", HEALTH_RATE_LIMIT_RETRY_AFTER_SECONDS);
        res.status(429).json({ error: "too_many_requests" });
        return;
      }
      logError({ event: "health_ready_rate_limit_failed", error: String(err) });
      res.status(500).json({ error: "internal" });
      return;
    }
    // H13: surface whether crash reporting is actually enabled so the
    // post-deploy gate can probe the live endpoint for sentry.enabled=true and
    // fail closed when functions ship with SENTRY_DSN unset (shipping dark).
    const sentry = sentryStatus();
    const domainCore = domainCoreDeploymentIdentityForHealth();
    const core = domainCoreReadiness(domainCore);
    let probe: FirestoreReadiness;
    try {
      probe = await probeFirestoreReadiness();
    } catch (error) {
      // Client-construction failure (no RPC was possible): all-error, 503.
      logError({ event: "health_ready_failed", error: String(error) });
      res.status(503).json({
        status: "degraded",
        timestamp: new Date().toISOString(),
        version: FUNCTION_VERSION,
        domainCore,
        checks: { firestore: "error", firestoreTransaction: "error", domainCore: core.check },
        sentry,
        error: "Firestore connectivity check failed",
        ...sourceMetadata(),
      });
      return;
    }
    const ready =
      probe.firestore === "ok" &&
      probe.firestoreTransaction === "ok" &&
      (!core.gatesVerdict || core.check === "loaded");
    const checks = {
      firestore: probe.firestore,
      firestoreTransaction: probe.firestoreTransaction,
      domainCore: core.check,
    };
    if (ready) {
      logInfo({ event: "health_ready_ok", latency_ms: probe.latencyMs, sentry_enabled: sentry.enabled });
      res.status(200).json({
        status: "ready",
        timestamp: new Date().toISOString(),
        version: FUNCTION_VERSION,
        domainCore,
        latency_ms: probe.latencyMs,
        checks,
        sentry,
        ...sourceMetadata(),
      });
      return;
    }
    const failed = Object.entries(checks)
      .filter(([, value]) => value === "error" || value === "unavailable")
      .map(([name]) => name);
    logError({ event: "health_ready_failed", error: `Readiness checks failed: ${failed.join(", ")}` });
    res.status(503).json({
      status: "degraded",
      timestamp: new Date().toISOString(),
      version: FUNCTION_VERSION,
      domainCore,
      latency_ms: probe.latencyMs,
      checks,
      sentry,
      error: "Firestore connectivity check failed",
      ...sourceMetadata(),
    });
  }),
);

/**
 * Combined health check — returns full status, version, uptime, and all
 * dependency health. Used by monitoring dashboards and deployment scripts.
 * Same verdict inputs as healthReady; a 429 here likewise means "retry", not
 * DOWN (see liveness contract above).
 */
export const healthCheck = onRequest(
  { region: FUNCTIONS_REGION, cors: false, invoker: "public" },
  wrapRequestHandler("healthCheck", async (req, res) => {
    setPublicJsonSecurityHeaders(res);
    try {
      await checkPublicHttpEndpointRateLimit("healthCheck", clientIpFromHttpRequest(req));
    } catch (err) {
      if (isPublicRateLimitExceeded(err)) {
        res.setHeader("Retry-After", HEALTH_RATE_LIMIT_RETRY_AFTER_SECONDS);
        res.status(429).json({ error: "too_many_requests" });
        return;
      }
      logError({ event: "health_check_rate_limit_failed", error: String(err) });
      res.status(500).json({ error: "internal" });
      return;
    }
    const domainCore = domainCoreDeploymentIdentityForHealth();
    const core = domainCoreReadiness(domainCore);
    let probe: FirestoreReadiness;
    try {
      probe = await probeFirestoreReadiness();
    } catch {
      probe = { latencyMs: 0, firestore: "error", firestoreTransaction: "error" };
    }
    const checks = {
      firestore: probe.firestore,
      firestoreTransaction: probe.firestoreTransaction,
      domainCore: core.check,
    };

    const allHealthy =
      probe.firestore === "ok" &&
      probe.firestoreTransaction === "ok" &&
      (!core.gatesVerdict || core.check === "loaded");

    logInfo({
      event: "health_check",
      firestore: probe.firestore,
      firestore_transaction: probe.firestoreTransaction,
      domain_core: core.check,
      latency_ms: probe.latencyMs,
      healthy: allHealthy,
    });

    res.status(allHealthy ? 200 : 503).json({
      status: allHealthy ? "ok" : "degraded",
      timestamp: new Date().toISOString(),
      version: FUNCTION_VERSION,
      domainCore,
      uptime_ms: Math.round(process.uptime() * 1000),
      checks,
      ...(probe.latencyMs > 0 && { latency_ms: probe.latencyMs }),
      ...sourceMetadata(),
    });
  }),
);
