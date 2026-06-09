/**
 * Rate limits for unauthenticated public HTTP endpoints and high-risk approval callables.
 */

import { createHash } from "node:crypto";

import { HttpsError } from "firebase-functions/v2/https";
import { Timestamp } from "firebase-admin/firestore";

import { db } from "../adminRuntime.js";

export type PublicHttpRateLimitAction = "cli_link_start" | "hermes_gateway_device_start";

export type CallableApprovalRateLimitAction = "cli_link_approve_fail" | "hermes_gateway_approve_fail";

export type HermesGatewayBearerRateLimitAction =
  | "hermes_gateway_message_send"
  | "hermes_gateway_attachment_init";

const PUBLIC_HTTP_LIMITS: Record<PublicHttpRateLimitAction, { windowSeconds: number; maxAttempts: number }> = {
  cli_link_start: { windowSeconds: 3600, maxAttempts: 20 },
  hermes_gateway_device_start: { windowSeconds: 3600, maxAttempts: 20 },
};

const APPROVAL_LIMITS: Record<CallableApprovalRateLimitAction, { windowSeconds: number; maxAttempts: number }> = {
  cli_link_approve_fail: { windowSeconds: 900, maxAttempts: 10 },
  hermes_gateway_approve_fail: { windowSeconds: 900, maxAttempts: 10 },
};

const HERMES_GATEWAY_BEARER_LIMITS: Record<
  HermesGatewayBearerRateLimitAction,
  { windowSeconds: number; maxAttempts: number }
> = {
  hermes_gateway_message_send: { windowSeconds: 60, maxAttempts: 120 },
  hermes_gateway_attachment_init: { windowSeconds: 600, maxAttempts: 20 },
};

function rateLimitDocId(keyMaterial: string, action: string): string {
  const hash = createHash("sha256").update(`${keyMaterial}:${action}`).digest("hex");
  return `${action}_${hash.slice(0, 40)}`;
}

export function clientIpFromHttpRequest(req: {
  headers?: Record<string, unknown>;
  ip?: string;
  socket?: { remoteAddress?: string };
}): string {
  if (typeof req.ip === "string" && req.ip.length > 0) return req.ip;
  const remote = req.socket?.remoteAddress;
  if (typeof remote === "string" && remote.length > 0) return remote;
  if (process.env.OPENBURNBAR_TRUST_X_FORWARDED_FOR !== "1") return "unknown";
  const forwarded = req.headers?.["x-forwarded-for"];
  if (typeof forwarded === "string") {
    const first = forwarded.split(",")[0]?.trim();
    if (first) return first;
  }
  return "unknown";
}

async function incrementRateLimit(
  docId: string,
  action: string,
  limit: { windowSeconds: number; maxAttempts: number },
): Promise<void> {
  const ref = db.doc(`public_rate_limits/${docId}`);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = Date.now();
    const data = snap.data();
    let count = typeof data?.count === "number" ? data.count : 0;
    let windowStartMillis = typeof data?.windowStartMillis === "number" ? data.windowStartMillis : 0;
    if (now - windowStartMillis > limit.windowSeconds * 1000) {
      count = 0;
      windowStartMillis = now;
    }
    if (count >= limit.maxAttempts) {
      throw new HttpsError("resource-exhausted", "Too many requests. Try again later.");
    }
    tx.set(
      ref,
      {
        action,
        count: count + 1,
        windowStartMillis,
        updatedAt: Timestamp.now(),
        schemaVersion: 1,
      },
      { merge: true },
    );
  });
}

export async function checkPublicHttpRateLimit(keyMaterial: string, action: PublicHttpRateLimitAction): Promise<void> {
  const limit = PUBLIC_HTTP_LIMITS[action];
  await incrementRateLimit(rateLimitDocId(keyMaterial, action), action, limit);
}

export async function checkHermesGatewayBearerRateLimit(
  uid: string,
  clientId: string,
  action: HermesGatewayBearerRateLimitAction,
): Promise<void> {
  const limit = HERMES_GATEWAY_BEARER_LIMITS[action];
  await incrementRateLimit(rateLimitDocId(`${uid}:${clientId}`, action), action, limit);
}

export async function recordCallableApprovalFailure(
  uid: string,
  action: CallableApprovalRateLimitAction,
): Promise<void> {
  const limit = APPROVAL_LIMITS[action];
  await incrementRateLimit(rateLimitDocId(uid, action), action, limit);
}

export async function assertCallableApprovalNotLocked(
  uid: string,
  action: CallableApprovalRateLimitAction,
): Promise<void> {
  const limit = APPROVAL_LIMITS[action];
  const ref = db.doc(`public_rate_limits/${rateLimitDocId(uid, action)}`);
  const snap = await ref.get();
  if (!snap.exists) return;
  const data = snap.data();
  const count = typeof data?.count === "number" ? data.count : 0;
  const windowStartMillis = typeof data?.windowStartMillis === "number" ? data.windowStartMillis : 0;
  const elapsed = Date.now() - windowStartMillis;
  if (elapsed <= limit.windowSeconds * 1000 && count >= limit.maxAttempts) {
    throw new HttpsError("resource-exhausted", "Too many failed approval attempts. Try again later.");
  }
}
