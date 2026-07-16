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
 */

import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { onRequest } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";
import { logInfo, logError } from "./logging.js";
import { FUNCTIONS_REGION } from "./runtimeOptions.js";
import { sourceMetadata } from "./sourceMetadata.js";
import { domainCoreDeploymentIdentity } from "./domainCoreBuildProfile.js";
import { loadedDomainCorePricingIdentity } from "./domainCorePricing.js";
import { sentryStatus } from "./sentry.js";
import { setPublicJsonSecurityHeaders } from "./publicHttpSecurityHeaders.js";
import {
  checkPublicHttpEndpointRateLimit,
  clientIpFromHttpRequest,
  isPublicRateLimitExceeded,
} from "./callables/publicRateLimit.js";

const FUNCTION_VERSION = process.env.FUNCTION_VERSION ?? "unknown";
const MANIFEST_FILE_NAME = "domain-core-runtime-artifact-manifest.json";
const manifestPath = resolve(__dirname, MANIFEST_FILE_NAME);

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

/**
 * Probe Firestore with a hard timeout. Returns the probe latency in ms.
 * Throws if Firestore is unreachable or exceeds the timeout.
 * Uses clearTimeout to avoid timer leaks in warm container instances.
 */
async function probeFirestore(timeoutMs = 3000): Promise<number> {
  const startMs = Date.now();
  let timer: ReturnType<typeof setTimeout> | undefined;

  const timeoutPromise = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`Firestore probe timed out after ${timeoutMs}ms`)), timeoutMs);
  });

  try {
    const db = getFirestore();
    await Promise.race([db.collection("_health").doc("probe").get(), timeoutPromise]);
    return Date.now() - startMs;
  } finally {
    clearTimeout(timer);
  }
}

/** Liveness probe — returns 200 if the function process is alive. */
export const healthLive = onRequest({ region: FUNCTIONS_REGION, cors: false, invoker: "public" }, async (req, res) => {
  setPublicJsonSecurityHeaders(res);
  try {
    await checkPublicHttpEndpointRateLimit("healthLive", clientIpFromHttpRequest(req));
  } catch (err) {
    if (isPublicRateLimitExceeded(err)) {
      res.status(429).json({ error: "too_many_requests" });
      return;
    }
    logError({ event: "health_live_rate_limit_failed", error: String(err) });
    res.status(500).json({ error: "internal" });
    return;
  }
  res.status(200).json({
    status: "alive",
    timestamp: new Date().toISOString(),
    domainCore: domainCoreDeploymentIdentityForHealth(),
    ...sourceMetadata(),
  });
});

/**
 * Readiness probe — verifies Firestore responds within 3 seconds.
 * Returns 200 when ready, 503 when degraded.
 */
export const healthReady = onRequest(
  { region: FUNCTIONS_REGION, cors: false, invoker: "public" },
  async (req, res) => {
    setPublicJsonSecurityHeaders(res);
    try {
      await checkPublicHttpEndpointRateLimit("healthReady", clientIpFromHttpRequest(req));
    } catch (err) {
      if (isPublicRateLimitExceeded(err)) {
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
    try {
      const latencyMs = await probeFirestore();
      logInfo({ event: "health_ready_ok", latency_ms: latencyMs, sentry_enabled: sentry.enabled });
      res.status(200).json({
        status: "ready",
        timestamp: new Date().toISOString(),
        version: FUNCTION_VERSION,
        domainCore: domainCoreDeploymentIdentityForHealth(),
        latency_ms: latencyMs,
        checks: { firestore: "ok" },
        sentry,
        ...sourceMetadata(),
      });
    } catch (error) {
      logError({ event: "health_ready_failed", error: String(error) });
      res.status(503).json({
        status: "degraded",
        timestamp: new Date().toISOString(),
        version: FUNCTION_VERSION,
        domainCore: domainCoreDeploymentIdentityForHealth(),
        checks: { firestore: "error" },
        sentry,
        error: "Firestore connectivity check failed",
        ...sourceMetadata(),
      });
    }
  },
);

/**
 * Combined health check — returns full status, version, uptime, and all
 * dependency health. Used by monitoring dashboards and deployment scripts.
 */
export const healthCheck = onRequest(
  { region: FUNCTIONS_REGION, cors: false, invoker: "public" },
  async (req, res) => {
    setPublicJsonSecurityHeaders(res);
    try {
      await checkPublicHttpEndpointRateLimit("healthCheck", clientIpFromHttpRequest(req));
    } catch (err) {
      if (isPublicRateLimitExceeded(err)) {
        res.status(429).json({ error: "too_many_requests" });
        return;
      }
      logError({ event: "health_check_rate_limit_failed", error: String(err) });
      res.status(500).json({ error: "internal" });
      return;
    }
    let firestoreStatus: "ok" | "error" = "ok";
    let latencyMs = 0;

    try {
      latencyMs = await probeFirestore();
    } catch {
      firestoreStatus = "error";
    }

    const allHealthy = firestoreStatus === "ok";

    logInfo({
      event: "health_check",
      firestore: firestoreStatus,
      latency_ms: latencyMs,
      healthy: allHealthy,
    });

    res.status(allHealthy ? 200 : 503).json({
      status: allHealthy ? "ok" : "degraded",
      timestamp: new Date().toISOString(),
      version: FUNCTION_VERSION,
      domainCore: domainCoreDeploymentIdentityForHealth(),
      uptime_ms: Math.round(process.uptime() * 1000),
      checks: { firestore: firestoreStatus },
      ...(latencyMs > 0 && { latency_ms: latencyMs }),
      ...sourceMetadata(),
    });
  },
);