/**
 * Health check endpoint for OpenBurnBar Cloud Functions.
 *
 * Exposes:
 *   GET /healthCheck  → 200 { status: "ok", timestamp, version, uptime_ms, checks }
 *   GET /healthLive   → 200 { status: "alive" } — liveness probe for load balancers
 *   GET /healthReady  → 200/503 — readiness probe; 503 if Firestore unreachable
 *
 * All three are public (no auth) and safe to hit from monitoring tools.
 * Usage: curl https://us-central1-<project>.cloudfunctions.net/healthCheck
 */

import { onRequest } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";
import { logInfo, logError } from "./logging.js";

const FUNCTION_VERSION = process.env.FUNCTION_VERSION ?? "unknown";

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
    if (timer !== undefined) clearTimeout(timer);
  }
}

/** Liveness probe — returns 200 if the function process is alive. */
export const healthLive = onRequest({ region: "us-central1", cors: false, invoker: "public" }, (_req, res) => {
  res.status(200).json({ status: "alive", timestamp: new Date().toISOString() });
});

/**
 * Readiness probe — verifies Firestore responds within 3 seconds.
 * Returns 200 when ready, 503 when degraded.
 */
export const healthReady = onRequest({ region: "us-central1", cors: false, invoker: "public" }, async (_req, res) => {
  try {
    const latencyMs = await probeFirestore();
    logInfo({ event: "health_ready_ok", latency_ms: latencyMs });
    res.status(200).json({
      status: "ready",
      timestamp: new Date().toISOString(),
      version: FUNCTION_VERSION,
      latency_ms: latencyMs,
      checks: { firestore: "ok" },
    });
  } catch (error) {
    logError({ event: "health_ready_failed", error: String(error) });
    res.status(503).json({
      status: "degraded",
      timestamp: new Date().toISOString(),
      version: FUNCTION_VERSION,
      checks: { firestore: "error" },
      error: "Firestore connectivity check failed",
    });
  }
});

/**
 * Combined health check — returns full status, version, uptime, and all
 * dependency health. Used by monitoring dashboards and deployment scripts.
 */
export const healthCheck = onRequest({ region: "us-central1", cors: false, invoker: "public" }, async (_req, res) => {
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
    uptime_ms: Math.round(process.uptime() * 1000),
    checks: { firestore: firestoreStatus },
    ...(latencyMs > 0 && { latency_ms: latencyMs }),
  });
});
