/**
 * @fileoverview Provider account, connection, and pairing audit helpers plus their
 * shared schema constants and quota-provider registries.
 */

import { Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { randomBytes } from "node:crypto";

import type {
  Provider,
  CredentialKind,
  ProviderAccountDoc,
  ProviderConnectionDoc,
  HermesConnectionAuditEventDoc,
  PiAgentConnectionAuditEventDoc,
} from "../../types.js";
import { stripUndefinedObject } from "../../guards.js";
import { db } from "../../adminRuntime.js";
import { assertProvider, nowISO } from "./validators.js";

const CONNECTION_SCHEMA_VERSION = 1;
export const ACCOUNT_SCHEMA_VERSION = 2;
export const HERMES_SCHEMA_VERSION = 1;
export const HERMES_PAIRING_TTL_MS = 10 * 60 * 1000;
const HERMES_PAIRING_AUDIT_TTL_MS = 90 * 24 * 60 * 60 * 1000;
export const HERMES_MAX_FAILED_PAIRING_ATTEMPTS = 5;
export const PI_AGENT_SCHEMA_VERSION = 1;
export const PI_AGENT_PAIRING_TTL_MS = 10 * 60 * 1000;
const PI_AGENT_PAIRING_AUDIT_TTL_MS = 90 * 24 * 60 * 60 * 1000;
export const PI_AGENT_MAX_FAILED_PAIRING_ATTEMPTS = 5;
export const HOSTED_QUOTA_PROVIDERS = new Set<string>(["codex"]);
const SELF_HOSTED_QUOTA_PROVIDERS = new Set<string>(["claude-code", "codex", "opencode", "antigravity"]);

export async function writeHermesAuditEvent(
  uid: string,
  event: Omit<HermesConnectionAuditEventDoc, "id" | "observedAt" | "schemaVersion" | "expireAt">,
): Promise<void> {
  const id = `${Date.now()}_${randomBytes(6).toString("hex")}`;
  const expireAt = Timestamp.fromMillis(Date.now() + HERMES_PAIRING_AUDIT_TTL_MS);
  const doc: HermesConnectionAuditEventDoc = {
    id,
    ...event,
    observedAt: nowISO(),
    schemaVersion: HERMES_SCHEMA_VERSION,
    expireAt,
  };
  await db.doc(`users/${uid}/hermes_audit_events/${id}`).set(stripUndefinedObject(doc));
}

export async function writePiAgentAuditEvent(
  uid: string,
  event: Omit<PiAgentConnectionAuditEventDoc, "id" | "observedAt" | "schemaVersion" | "expireAt">,
): Promise<void> {
  const id = `${Date.now()}_${randomBytes(6).toString("hex")}`;
  const expireAt = Timestamp.fromMillis(Date.now() + PI_AGENT_PAIRING_AUDIT_TTL_MS);
  const doc: PiAgentConnectionAuditEventDoc = {
    id,
    ...event,
    observedAt: nowISO(),
    schemaVersion: PI_AGENT_SCHEMA_VERSION,
    expireAt,
  };
  await db.doc(`users/${uid}/pi_agent_audit_events/${id}`).set(stripUndefinedObject(doc));
}

export function accountIDFor(provider: string, requestedAccountID?: string): string {
  const raw = requestedAccountID?.trim() || `${provider}_default`;
  const safe = raw
    .toLowerCase()
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  if (!safe) {
    throw new HttpsError("invalid-argument", "Account ID must contain letters or numbers.");
  }
  return safe;
}

export function connectionDocFromAccount(account: ProviderAccountDoc): ProviderConnectionDoc {
  assertProvider(account.providerID);
  return {
    provider: account.providerID,
    status: account.status === "disabled" || account.status === "deleted" ? "disconnected" : account.status,
    lastValidatedAt: account.lastValidatedAt,
    lastRefreshAt: account.lastRefreshAt,
    lastErrorCode: account.lastErrorCode,
    credentialKind: account.credentialKind,
    redactedLabel: account.redactedLabel,
    schemaVersion: CONNECTION_SCHEMA_VERSION,
  };
}

export function assertHostedProvider(provider: string): asserts provider is Provider {
  assertProvider(provider);
  if (!HOSTED_QUOTA_PROVIDERS.has(provider)) {
    throw new HttpsError(
      "invalid-argument",
      `Hosted quota sync is currently available for ${Array.from(HOSTED_QUOTA_PROVIDERS).join(", ")} only.`,
    );
  }
}

export function hostedProviderLabel(provider: string): string {
  switch (provider) {
    case "codex":
      return "Codex";
    case "claude-code":
      return "Claude Code";
    case "kimi":
      return "Kimi";
    case "antigravity":
      return "Antigravity";
    default:
      return provider;
  }
}

export function hostedCredentialKind(provider: string): CredentialKind {
  switch (provider) {
    case "codex":
    case "claude-code":
    case "antigravity":
      return "session";
    default:
      return "bearer";
  }
}

export function assertSelfHostedProvider(provider: string): asserts provider is Provider {
  assertProvider(provider);
  if (!SELF_HOSTED_QUOTA_PROVIDERS.has(provider)) {
    throw new HttpsError(
      "invalid-argument",
      `Self-hosted quota sync is available for ${Array.from(SELF_HOSTED_QUOTA_PROVIDERS).join(", ")}.`,
    );
  }
}
