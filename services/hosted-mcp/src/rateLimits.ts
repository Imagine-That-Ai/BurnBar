import type { Firestore } from "firebase-admin/firestore";
import { Timestamp } from "firebase-admin/firestore";
import { HttpError } from "./errors.js";
import type { HostedMcpFirestore } from "./firestoreTypes.js";

const LIMITS: Record<string, { windowMs: number; max: number }> = {
  "search:standard": { windowMs: 60_000, max: 60 },
  "body:standard": { windowMs: 60_000, max: 30 },
  "metadata:standard": { windowMs: 60_000, max: 120 },
  // Pensieve knowledge query buckets. Without these entries the bucket would
  // silently fall back to metadata:standard (120/min); they MUST be registered.
  "knowledge:standard": { windowMs: 60_000, max: 60 }, // Pro tier
  "search:ultra": { windowMs: 60_000, max: 180 } // Ultra tier
};

export async function enforceRateLimit(db: HostedMcpFirestore, uid: string, clientId: string, bucket: string): Promise<void> {
  const spec = LIMITS[bucket] ?? LIMITS["metadata:standard"];
  const windowStart = Math.floor(Date.now() / spec.windowMs) * spec.windowMs;
  const id = `${clientId}_${bucket}_${windowStart}`.replace(/[^A-Za-z0-9_.:-]/g, "_");
  const ref = db.doc(`users/${uid}/remote_mcp_rate_limits/${id}`);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const count = Number(snap.get("count") ?? 0);
    if (count >= spec.max) {
      throw new HttpError(429, "Hosted MCP rate limit exceeded.", "rate_limited");
    }
    tx.set(ref, {
      uid,
      clientIdHash: clientId,
      bucket,
      windowStart: Timestamp.fromMillis(windowStart),
      expiresAt: Timestamp.fromMillis(windowStart + spec.windowMs * 2),
      count: count + 1,
      schemaVersion: 1
    }, { merge: true });
  });
}
