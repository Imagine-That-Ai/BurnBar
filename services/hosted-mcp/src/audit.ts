import { createHash } from "node:crypto";
import { Timestamp, type Firestore } from "firebase-admin/firestore";
import type { AccessTokenClaims } from "./auth.js";

function hash(value: string | undefined): string | undefined {
  if (!value) return undefined;
  return createHash("sha256").update(value).digest("hex").slice(0, 32);
}

export async function writeAuditEvent(
  db: Firestore,
  claims: AccessTokenClaims,
  fields: {
    kind: string;
    toolName?: string;
    resultCount?: number;
    denyReason?: string;
    latencyMs?: number;
    queryHashCount?: number;
    ip?: string;
    userAgent?: string;
  }
): Promise<void> {
  const id = `${Date.now()}_${createHash("sha256").update(`${claims.jti}:${fields.kind}:${Math.random()}`).digest("hex").slice(0, 16)}`;
  await db.doc(`users/${claims.sub}/remote_mcp_audit_events/${id}`).set({
    eventKind: fields.kind,
    traceID: id,
    hashedClientID: hash(claims.client_id),
    hashedIPPrefix: hash(fields.ip?.split(".").slice(0, 3).join(".")),
    hashedUserAgent: hash(fields.userAgent),
    scopes: claims.scopes,
    toolName: fields.toolName,
    resultCount: fields.resultCount ?? 0,
    denyReason: fields.denyReason,
    entitlementSource: claims.entitlement_family,
    tokenJtiHash: hash(claims.jti),
    opaqueQueryHashCount: fields.queryHashCount ?? 0,
    latencyBucket: fields.latencyMs === undefined ? "unknown" : fields.latencyMs < 300 ? "lt_300ms" : fields.latencyMs < 900 ? "lt_900ms" : "gte_900ms",
    costBucket: fields.toolName?.includes("body") ? "body" : "metadata",
    createdAt: Timestamp.now(),
    schemaVersion: 1
  });
}
