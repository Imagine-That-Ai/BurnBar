/**
 * @fileoverview exportUserData — privacy-control-center data export (GDPR/portability).
 *
 * Returns the member's data, one entry per data domain, derived from the
 * canonical data-domain registry (packages/data-domains/registry.json), mirrored
 * here as {@link DATA_DOMAIN_PATHS} with a drift guard (a unit test asserts the
 * ids + firestorePaths match the registry, exactly like dataDomainUsage.ts).
 *
 * Encryption-tier policy (server NEVER sees plaintext or the vault key):
 *   - server_readable + zero_access domains: emitted INLINE as plaintext JSON
 *     (the server can already read these facets; for zero_access only the opaque
 *     metadata/manifests live in Firestore, the sealed payload stays on device).
 *   - end_to_end domains: emitted as `sealedRefs` — signed-URL references to the
 *     Cloud Storage ciphertext objects the client downloads + decrypts on-device
 *     with its vault key. Inline Firestore docs for E2E domains carry only sealed
 *     envelopes / opaque hashes, so they are also returned inline (still opaque).
 *
 * Reuses getEncryptedSessionBlobDownloadUrl's signed-URL pattern (encryptedSearch.ts)
 * for sealedRefs and appends a tamper-evident audit event (auditLog.ts).
 */

import { getStorage } from "firebase-admin/storage";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { getConfig } from "../config.js";
import { enforceAuthAndAppCheck } from "../auth.js";
import { db } from "../adminRuntime.js";
import { wrapCallableHandler } from "../logging.js";
import { stripUndefinedObject } from "../guards.js";
import { nowISO, requireBoundedStringArray, sha256Hex } from "./shared.js";
import { appendAuditEventRequired, auditActorLabel, AUDIT_ACTIONS } from "./auditLog.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

export type EncryptionTier = "server_readable" | "zero_access" | "end_to_end";

export interface DomainPaths {
  encryptionTier: EncryptionTier;
  /** Top-level Firestore collection names under users/{uid}/ for this domain. */
  firestoreCollections: string[];
  /**
   * Cloud Storage path templates under users/{uid}/ for this domain (the
   * `{...}` segments are wildcards). Stored as the SEGMENT BEFORE the first
   * `{` so the same prefix drives both export refs and recursive delete.
   */
  storagePrefixes: string[];
}

/**
 * Server-authoritative per-domain path map. Ids + firestoreCollections +
 * storagePrefixes MUST match packages/data-domains/registry.json — enforced by
 * dataExport.test.ts so the two never drift.
 */
export const DATA_DOMAIN_PATHS: Record<string, DomainPaths> = {
  usage_spend: {
    encryptionTier: "server_readable",
    firestoreCollections: [
      "usage",
      "usage_rollups",
      "usage_counter_days",
      "usage_counter_totals",
      "recent_usage",
      "quota_snapshots",
      "rollup_jobs",
      "projects",
    ],
    storagePrefixes: [],
  },
  conversations_chat: {
    encryptionTier: "server_readable",
    firestoreCollections: [
      "conversations",
      "chat_threads",
      "mobile_assistant_chats",
      "cli_sessions",
      "cli_agent_mission_requests",
      "text_snippets",
    ],
    storagePrefixes: [],
  },
  session_logs: {
    encryptionTier: "end_to_end",
    firestoreCollections: [
      "session_logs",
      "cloud_search_documents",
      "cloud_search_chunks",
      "cloud_search_postings",
      "cloud_search_index_state",
      "cloud_search_index_manifest",
      "project_memory_snapshots",
    ],
    storagePrefixes: ["session_logs"],
  },
  pensieve: {
    encryptionTier: "end_to_end",
    firestoreCollections: ["cloud_search_knowledge", "knowledge_sync_manifests", "knowledge_repos"],
    storagePrefixes: [],
  },
  provider_accounts: {
    encryptionTier: "server_readable",
    firestoreCollections: [
      "provider_accounts",
      "provider_connections",
      "provider_account_device_links",
      "runtime_connection_preferences",
    ],
    storagePrefixes: [],
  },
  connected_devices: {
    encryptionTier: "server_readable",
    firestoreCollections: [
      "devices",
      "hermes_connections",
      "hermes_pairings",
      "hermes_relay_requests",
      "hermes_session_cache",
      "hermes_gateway_clients",
      "hermes_gateway_destinations",
      "hermes_gateway_events",
      "hermes_gateway_messages",
      "hermes_gateway_typing",
      "hermes_gateway_state",
      "hermes_gateway_attachments",
      "pi_agent_connections",
      "pi_agent_pairings",
      "pi_agent_relay_requests",
      "iroh_pairing",
      "iroh_pairing_keys",
      "runtime_connection_preferences",
    ],
    storagePrefixes: ["hermes_gateway_attachments"],
  },
  external_mcp: {
    encryptionTier: "server_readable",
    firestoreCollections: ["remote_mcp_clients", "remote_mcp_grants", "remote_mcp_audit_events", "remote_mcp_rate_limits"],
    storagePrefixes: [],
  },
  computer_use: {
    encryptionTier: "zero_access",
    firestoreCollections: [
      "computer_use_sessions",
      "computer_use_actions",
      "computer_use_quota_usage",
      "agent_grant_authorities",
      "agent_capability_grant_requests",
    ],
    storagePrefixes: [],
  },
  media: {
    encryptionTier: "zero_access",
    firestoreCollections: ["media_session_events", "media_quota_usage", "media_attachment_manifests"],
    storagePrefixes: [],
  },
  entitlements_billing: {
    encryptionTier: "server_readable",
    firestoreCollections: ["entitlements", "entitlement_events", "entitlement_bindings"],
    storagePrefixes: [],
  },
  device_trust_keys: {
    encryptionTier: "end_to_end",
    firestoreCollections: [
      "cloud_vault_key_wrappers",
      "escrow_devices",
      "escrow_public_keys",
      "escrow_grants",
      "escrow_envelopes",
      "escrow_audit_events",
      "account_recovery_methods",
    ],
    storagePrefixes: [],
  },
  audit_timeline: {
    encryptionTier: "server_readable",
    firestoreCollections: [
      "remote_mcp_audit_events",
      "hermes_audit_events",
      "pi_agent_audit_events",
      "iroh_audit_events",
      "escrow_audit_events",
      "entitlement_events",
      "budgetEvents",
      "unified_audit_log",
    ],
    storagePrefixes: [],
  },
};

/** Hard cap on docs exported inline per collection (keeps payloads bounded). */
const MAX_INLINE_DOCS_PER_COLLECTION = 1000;
/** Hard cap on sealed-ref signed URLs minted per export call. */
const MAX_SEALED_REFS = 2000;
const SIGNED_URL_TTL_MS = 15 * 60 * 1000;

interface DomainExport {
  id: string;
  encryptionTier: EncryptionTier;
  inlineJson?: Record<string, unknown>;
  sealedRefs?: Array<{ path: string; bodyHash: string; signedUrl: string }>;
}

/** Collect plaintext/opaque Firestore docs for a domain, capped per collection. */
async function collectInlineJson(uid: string, paths: DomainPaths): Promise<Record<string, unknown>> {
  const inline: Record<string, unknown> = {};
  for (const collection of paths.firestoreCollections) {
    try {
      const snap = await db.collection(`users/${uid}/${collection}`).limit(MAX_INLINE_DOCS_PER_COLLECTION).get();
      if (snap.empty) continue;
      inline[collection] = snap.docs.map((doc) => ({ id: doc.id, ...serializeDoc(doc.data()) }));
    } catch {
      // Missing/empty collection — skip rather than fail the whole export.
    }
  }
  return inline;
}

/** Firestore Timestamps → ISO strings; everything else passed through. */
function serializeDoc(data: FirebaseFirestore.DocumentData): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(data)) {
    out[key] = serializeValue(value);
  }
  return out;
}

function serializeValue(value: unknown): unknown {
  if (value && typeof value === "object" && "toDate" in value && typeof (value as { toDate: unknown }).toDate === "function") {
    try {
      return (value as { toDate: () => Date }).toDate().toISOString();
    } catch {
      return String(value);
    }
  }
  if (Array.isArray(value)) return value.map(serializeValue);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) out[k] = serializeValue(v);
    return out;
  }
  return value;
}

/**
 * Mint short-lived signed-URL refs for an E2E domain's Cloud Storage ciphertext
 * objects. Mirrors getEncryptedSessionBlobDownloadUrl: v4 read URL, existence is
 * implied by listFiles. The client downloads + decrypts on-device.
 */
async function collectSealedRefs(
  uid: string,
  paths: DomainPaths,
  budget: { remaining: number },
): Promise<Array<{ path: string; bodyHash: string; signedUrl: string }>> {
  if (paths.storagePrefixes.length === 0 || budget.remaining <= 0) return [];
  const bucket = getStorage().bucket();
  const refs: Array<{ path: string; bodyHash: string; signedUrl: string }> = [];
  const expires = new Date(Date.now() + SIGNED_URL_TTL_MS);
  for (const prefix of paths.storagePrefixes) {
    if (budget.remaining <= 0) break;
    const [files] = await bucket.getFiles({ prefix: `users/${uid}/${prefix}/`, maxResults: budget.remaining });
    for (const file of files) {
      if (budget.remaining <= 0) break;
      const [signedUrl] = await file.getSignedUrl({ version: "v4", action: "read", expires });
      refs.push({
        path: file.name,
        bodyHash: deriveBodyHashFromPath(file.name),
        signedUrl,
      });
      budget.remaining -= 1;
    }
  }
  return refs;
}

/** The bodyHash is the object's basename sans the .json.aesgcm suffix, when present. */
function deriveBodyHashFromPath(path: string): string {
  const basename = path.split("/").pop() ?? path;
  const stripped = basename.endsWith(".json.aesgcm") ? basename.slice(0, -".json.aesgcm".length) : basename;
  return /^[a-f0-9]{32,128}$/u.test(stripped) ? stripped : sha256Hex(path);
}

export const exportUserData = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 20,
    timeoutSeconds: 300,
    memory: "512MiB",
  },
  wrapCallableHandler("exportUserData", async (request: CallableRequest<{ domains?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in before exporting your data.");
    enforceAuthAndAppCheck(request, uid);

    const requestedDomains =
      request.data?.domains == null ? [] : requireBoundedStringArray(request.data.domains, "domains", 24, 64);
    const ids = requestedDomains.length > 0 ? requestedDomains : Object.keys(DATA_DOMAIN_PATHS);
    for (const id of ids) {
      if (!(id in DATA_DOMAIN_PATHS)) {
        throw new HttpsError("invalid-argument", `Unknown data domain "${id}".`);
      }
    }

    const sealedBudget = { remaining: MAX_SEALED_REFS };
    const domains: DomainExport[] = [];
    for (const id of ids) {
      const paths = DATA_DOMAIN_PATHS[id];
      const [inlineJson, sealedRefs] = await Promise.all([
        collectInlineJson(uid, paths),
        collectSealedRefs(uid, paths, sealedBudget),
      ]);
      domains.push(
        stripUndefinedObject({
          id,
          encryptionTier: paths.encryptionTier,
          inlineJson: Object.keys(inlineJson).length > 0 ? inlineJson : undefined,
          sealedRefs: sealedRefs.length > 0 ? sealedRefs : undefined,
        }) as DomainExport,
      );
    }

    // Fail-CLOSED: an export is an irreversible disclosure, so it must leave an
    // audit record. If the audit write fails the error propagates and the export
    // is refused — a server cannot silently disclose data without a record.
    await appendAuditEventRequired(uid, {
      actor: auditActorLabel(request),
      action: AUDIT_ACTIONS.dataExport,
      domain: ids.length === Object.keys(DATA_DOMAIN_PATHS).length ? "all" : ids.join(","),
    });

    return { ok: true, generatedAt: nowISO(), domains, schemaVersion: 1 };
  }),
);
