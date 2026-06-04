/**
 * @fileoverview exportUserData — privacy-control-center data export (GDPR/portability).
 *
 * Returns the member's data, one entry per data domain, derived from the
 * canonical data-domain registry (packages/data-domains/registry.json), mirrored
 * here as {@link DATA_DOMAIN_PATHS} with a drift guard (a unit test asserts the
 * ids + firestorePaths match the registry, exactly like dataDomainUsage.ts).
 *
 * Encryption-tier policy (server NEVER sees plaintext or the vault key) —
 * ENFORCED, not merely asserted (privacy-leak-remediation-2026-06-02 §5):
 *   - server_readable domains: emitted INLINE verbatim (the server can already
 *     read these facets by definition).
 *   - end_to_end + zero_access domains (AND the sealed gateway content
 *     collections under the otherwise-server_readable connected_devices domain —
 *     see SEAL_AWARE_CONTENT_COLLECTIONS): a DEFAULT-DENY field allowlist
 *     (`sealAwareSerializeDoc`) emits ONLY the doc `id`, structurally-detected
 *     sealed envelopes (`isSealedEnvelope` — AES-256-GCM text/blob AND the
 *     Hermes gateway `relayEnvelope`, v2/v3 relay wraps), opaque
 *     cryptographic columns (slugHmac, dedupHash, vectorId, embedding,
 *     repoMatchToken, docID, projectKeyHash, relayEncryption/relayKeyVersion,
 *     sealedFilename/sealedAgentURI/sealedTopicID, gateway routing metadata, …),
 *     and Timestamps/numbers/bools. Every other top-level string (where cleartext
 *     titles/paths/names/slugs/text/senderDisplayName/fileName live) is DROPPED
 *     and recorded in a per-collection `redactedFields[]` so the export stays
 *     honest.
 *     Large E2E bodies still flow as `sealedRefs`. The user is the vault-key
 *     holder, so the sealed envelopes decrypt locally — no plaintext is needed
 *     for the owner's benefit, and none is emitted.
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
    encryptionTier: "end_to_end",
    firestoreCollections: [
      "conversations",
      "chat_threads",
      "mobile_assistant_chats",
      "cli_sessions",
      "cli_agent_mission_requests",
      "text_snippets",
      "rollback_requests",
      "approval_policies",
      "agent_identities",
      "subscription_topics",
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
      "hermes_gateway_approvals",
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
    firestoreCollections: [
      "remote_mcp_clients",
      "remote_mcp_grants",
      "remote_mcp_audit_events",
      "remote_mcp_rate_limits",
    ],
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
      "cloud_vault_state",
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
      "agent_notification_events",
      "agent_notification_replies",
      "unified_audit_log",
      "audit_meta",
    ],
    storagePrefixes: [],
  },
};

/**
 * Collections that carry SEALED content even though their parent registry
 * domain's tier is `server_readable`/`zero_access` (a mixed domain). The hosted
 * chat gateway's content collections live under the otherwise-server_readable
 * `connected_devices` domain, but once the gateway is sealed end-to-end
 * (HermesRelayCrypto, gateway-e2e Wave 4) their per-doc `relayEnvelope` + sealed
 * fields must ride the default-deny seal-aware serializer so a plaintext
 * `text`/`senderDisplayName`/`fileName` can never round-trip through the export.
 * clients/destinations/typing/state/approvals stay server_readable (routing
 * metadata only). This is the dataExport-side reclassification mandated by the
 * CONTRACT honesty note without diverging from the registry's per-domain tier.
 */
const SEAL_AWARE_CONTENT_COLLECTIONS = new Set<string>([
  "hermes_gateway_events",
  "hermes_gateway_messages",
  "hermes_gateway_attachments",
]);

/** Hard cap on docs exported inline per collection (keeps payloads bounded). */
const MAX_INLINE_DOCS_PER_COLLECTION = 1000;
/** Hard cap on sealed-ref signed URLs minted per export call. */
const MAX_SEALED_REFS = 2000;
const SIGNED_URL_TTL_MS = 15 * 60 * 1000;

interface DomainExport {
  id: string;
  encryptionTier: EncryptionTier;
  inlineJson?: Record<string, unknown>;
  /**
   * For end_to_end/zero_access domains: the union of plaintext field keys the
   * seal-aware allowlist withheld, so the export is honest about what it dropped.
   */
  redactedFields?: string[];
  sealedRefs?: Array<{ pathDigest: string; signedUrl: string }>;
}

/**
 * Opaque cryptographic columns an end_to_end / zero_access doc may legitimately
 * round-trip through the export. These carry NO content — they are HMAC
 * trapdoors, doc-id keys, cloaked vectors, model/version tags, byte/index
 * counters, or other server-side filter inputs — so emitting them leaks nothing.
 * Everything NOT on this list (and not a sealed envelope / Timestamp / number /
 * bool) is a candidate plaintext leak and is dropped (privacy-leak-remediation-
 * 2026-06-02 §5).
 */
const OPAQUE_EXPORT_COLUMNS = new Set<string>([
  "id",
  "uid",
  "vectorId",
  "embedding",
  "embeddingModelVersion",
  "slugHmac",
  "dedupHash",
  "dedupHashVersion",
  "sourceKind",
  "byteCount",
  "chunkIndex",
  "schemaVersion",
  "repoMatchToken",
  "docID",
  "projectKeyHash",
  "bodyHashVersion",
  "storagePath",
  "tokenHashes",
  "semanticHashes",
  "contentHashVersion",
  // ── Sealed gateway / media / subscription routing columns (gateway-e2e Wave 4).
  //    The actual sealed sub-objects (`relayEnvelope`, `ratchetEnvelope`, and
  //    `sealed*` CloudVault fields) are emitted only when isSealedEnvelope detects
  //    their full structure; malformed objects with those names are redacted.
  "relayEncryption",
  "relayKeyVersion",
  "sequence",
  "kind",
  "blobHash",
  "mime",
  "size",
  "peerDeviceIdHash",
  "direction",
]);

const VERSION_GATED_HASH_COLUMNS: Record<string, string> = {
  bodyHash: "bodyHashVersion",
  contentHash: "contentHashVersion",
};

function opaqueHashVersion(data: FirebaseFirestore.DocumentData, versionKey: string): number {
  const raw = data[versionKey];
  return typeof raw === "number" ? raw : raw instanceof Number ? raw.valueOf() : 0;
}

function shouldExportOpaqueColumn(key: string, data: FirebaseFirestore.DocumentData): boolean {
  if (key === "storagePath" && storagePathEmbedsBodyHash(data[key])) {
    return opaqueHashVersion(data, "bodyHashVersion") >= 2;
  }
  const versionKey = VERSION_GATED_HASH_COLUMNS[key];
  if (versionKey) {
    return opaqueHashVersion(data, versionKey) >= 2;
  }
  return OPAQUE_EXPORT_COLUMNS.has(key);
}

function storagePathEmbedsBodyHash(value: unknown): boolean {
  return typeof value === "string" && /\/bodies\/[a-f0-9]{32,128}\.json\.aesgcm$/u.test(value);
}

/** A sealed envelope is opaque regardless of its key name, so it is detected structurally. */
export function isSealedEnvelope(value: unknown): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const v = value as Record<string, unknown>;
  // Mirrors requireSealedText (shared.ts): AES-256-GCM text envelope …
  if (
    v.algorithm === "AES-256-GCM" &&
    typeof v.nonce === "string" &&
    typeof v.ciphertext === "string" &&
    typeof v.tag === "string"
  ) {
    return true;
  }
  // … or a CloudVault blob/payload envelope (sealedBoxBase64 combined box).
  if (v.algorithm === "AES-256-GCM" && typeof v.sealedBoxBase64 === "string") {
    return true;
  }
  // … or a Hermes gateway relay envelope. v2 uses the authenticated 2-DH
  // p256-hkdf-sha256-aesgcm wrap; v3 uses RFC 9180 HPKE Auth and carries `enc`.
  // The sealed gateway sub-object carries only opaque base64 ciphertext +
  // wrapped key + the algorithm/version constants — no plaintext — so it is safe
  // to round-trip through the export verbatim (gateway-e2e Wave 4).
  if (
    (v.relayEncryption === "p256-hkdf-sha256-aesgcm" ||
      v.relayEncryption === "hpke-auth-p256-hkdfsha256-aes256gcm") &&
    typeof v.payloadCiphertext === "string" &&
    typeof v.wrappedKey === "string" &&
    (v.relayEncryption !== "hpke-auth-p256-hkdfsha256-aes256gcm" || typeof v.enc === "string")
  ) {
    return true;
  }
  // … or a Hermes gateway ratchet envelope. The header is routing/session
  // metadata; ciphertextBase64 carries the AES-GCM nonce+ciphertext+tag. The
  // plaintext body never appears as a sibling once the gateway serializer sees
  // this shape.
  const header = v.header as Record<string, unknown> | undefined;
  if (
    header &&
    typeof header === "object" &&
    header.algorithm === "OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM" &&
    header.version === 1 &&
    typeof header.sessionID === "string" &&
    typeof header.senderDeviceID === "string" &&
    typeof header.receiverDeviceID === "string" &&
    typeof header.ratchetPublicKeyBase64 === "string" &&
    typeof v.ciphertextBase64 === "string"
  ) {
    return true;
  }
  return false;
}

/** True for Firestore Timestamp-like, number, boolean, or null (all content-free). */
function isExportablePrimitive(value: unknown): boolean {
  if (value === null) return true;
  const t = typeof value;
  if (t === "number" || t === "boolean") return true;
  if (
    value &&
    t === "object" &&
    "toDate" in (value as object) &&
    typeof (value as { toDate: unknown }).toDate === "function"
  ) {
    return true;
  }
  return false;
}

/**
 * Collect Firestore docs for a domain, capped per collection. For server_readable
 * domains the docs are emitted verbatim; for end_to_end/zero_access domains they
 * pass through the seal-aware default-deny allowlist, and any withheld plaintext
 * keys are accumulated into `redactedFields`.
 */
async function collectInlineJson(
  uid: string,
  paths: DomainPaths,
): Promise<{ inline: Record<string, unknown>; redactedFields: string[] }> {
  const inline: Record<string, unknown> = {};
  const redacted = new Set<string>();
  const domainSealAware = paths.encryptionTier !== "server_readable";
  for (const collection of paths.firestoreCollections) {
    // Force seal-aware serialization for sealed-content collections that live in
    // an otherwise-server_readable domain (e.g. the now-sealed gateway content
    // collections under connected_devices), so plaintext can never leak.
    const sealAware = domainSealAware || SEAL_AWARE_CONTENT_COLLECTIONS.has(collection);
    try {
      const snap = await db.collection(`users/${uid}/${collection}`).limit(MAX_INLINE_DOCS_PER_COLLECTION).get();
      if (snap.empty) continue;
      inline[collection] = snap.docs.map((doc) => {
        if (!sealAware) return { id: doc.id, ...serializeDoc(doc.data()) };
        const { out, dropped } = sealAwareSerializeDoc(doc.data());
        for (const key of dropped) redacted.add(key);
        return { id: doc.id, ...out };
      });
    } catch {
      // Missing/empty collection — skip rather than fail the whole export.
    }
  }
  return { inline, redactedFields: [...redacted].sort() };
}

/** Firestore Timestamps → ISO strings; everything else passed through (server_readable only). */
function serializeDoc(data: FirebaseFirestore.DocumentData): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(data)) {
    out[key] = serializeValue(value);
  }
  return out;
}

/**
 * DEFAULT-DENY seal-aware serializer for end_to_end / zero_access docs. Emits a
 * field only if it is (a) a structurally-detected sealed envelope, (b) on the
 * opaque-column allowlist, or (c) a Timestamp/number/bool/null. Every other key
 * (top-level cleartext strings, arbitrary plaintext objects/arrays) is DROPPED
 * and reported via `dropped` so the export records `redactedFields[]`
 * (privacy-leak-remediation-2026-06-02 §5).
 */
export function sealAwareSerializeDoc(data: FirebaseFirestore.DocumentData): {
  out: Record<string, unknown>;
  dropped: string[];
} {
  const out: Record<string, unknown> = {};
  const dropped: string[] = [];
  for (const [key, value] of Object.entries(data)) {
    if (isSealedEnvelope(value)) {
      const sanitized = sanitizeSealedEnvelope(key, value);
      out[key] = sanitized.out; // opaque ciphertext — safe to emit after nested default-deny.
      dropped.push(...sanitized.dropped);
    } else if (shouldExportOpaqueColumn(key, data)) {
      out[key] = serializeValue(value); // opaque crypto column — safe to emit
    } else if (isExportablePrimitive(value)) {
      out[key] = serializeValue(value); // content-free scalar/timestamp
    } else {
      dropped.push(key); // candidate plaintext leak — withhold
    }
  }
  return { out, dropped };
}

const CLOUD_VAULT_SEALED_FIELDS = new Set([
  "schemaVersion",
  "algorithm",
  "keyVersion",
  "nonce",
  "ciphertext",
  "tag",
  "aad",
  "sealedBoxBase64",
  "plaintextHMAC",
  "integrityHashVersion",
  "createdAt",
]);

const HERMES_RELAY_ENVELOPE_FIELDS = new Set([
  "payloadCiphertext",
  "wrappedKey",
  "relayEncryption",
  "relayKeyVersion",
  "senderPublicKey",
  "enc",
]);

const HERMES_RATCHET_HEADER_FIELDS = new Set([
  "version",
  "sessionID",
  "senderDeviceID",
  "receiverDeviceID",
  "algorithm",
  "ratchetPublicKeyBase64",
  "previousChainLength",
  "messageNumber",
  "epoch",
]);

function sanitizeSealedEnvelope(
  key: string,
  value: unknown,
): {
  out: unknown;
  dropped: string[];
} {
  const serialized = serializeValue(value);
  if (!serialized || typeof serialized !== "object" || Array.isArray(serialized)) {
    return { out: serialized, dropped: [] };
  }
  const envelope = serialized as Record<string, unknown>;
  if (envelope.algorithm === "AES-256-GCM") {
    return sanitizeAllowedObject(key, envelope, CLOUD_VAULT_SEALED_FIELDS);
  }
  if (typeof envelope.relayEncryption === "string") {
    return sanitizeAllowedObject(key, envelope, HERMES_RELAY_ENVELOPE_FIELDS);
  }
  const header = envelope.header;
  if (header && typeof header === "object" && !Array.isArray(header)) {
    const outer = sanitizeAllowedObject(key, envelope, new Set(["header", "ciphertextBase64"]));
    const sanitizedHeader = sanitizeAllowedObject(
      `${key}.header`,
      header as Record<string, unknown>,
      HERMES_RATCHET_HEADER_FIELDS,
    );
    return {
      out: { ...(outer.out as Record<string, unknown>), header: sanitizedHeader.out },
      dropped: [...outer.dropped, ...sanitizedHeader.dropped],
    };
  }
  return { out: serialized, dropped: [] };
}

function sanitizeAllowedObject(
  path: string,
  data: Record<string, unknown>,
  allowed: Set<string>,
): {
  out: Record<string, unknown>;
  dropped: string[];
} {
  const out: Record<string, unknown> = {};
  const dropped: string[] = [];
  for (const [key, value] of Object.entries(data)) {
    if (key === "plaintextSHA256") {
      dropped.push(`${path}.${key}`);
      continue;
    }
    if ((key === "bodyHash" || key === "contentHash") && !shouldExportOpaqueColumn(key, data)) {
      dropped.push(`${path}.${key}`);
      continue;
    }
    if (!allowed.has(key)) {
      dropped.push(`${path}.${key}`);
      continue;
    }
    out[key] = serializeValue(value);
  }
  return { out, dropped };
}

function serializeValue(value: unknown): unknown {
  if (
    value &&
    typeof value === "object" &&
    "toDate" in value &&
    typeof (value as { toDate: unknown }).toDate === "function"
  ) {
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
): Promise<Array<{ pathDigest: string; signedUrl: string }>> {
  if (paths.storagePrefixes.length === 0 || budget.remaining <= 0) return [];
  const bucket = getStorage().bucket();
  const refs: Array<{ pathDigest: string; signedUrl: string }> = [];
  const expires = new Date(Date.now() + SIGNED_URL_TTL_MS);
  for (const prefix of paths.storagePrefixes) {
    if (budget.remaining <= 0) break;
    const [files] = await bucket.getFiles({ prefix: `users/${uid}/${prefix}/`, maxResults: budget.remaining });
    for (const file of files) {
      if (budget.remaining <= 0) break;
      const [signedUrl] = await file.getSignedUrl({ version: "v4", action: "read", expires });
      refs.push({
        pathDigest: sha256Hex(file.name),
        signedUrl,
      });
      budget.remaining -= 1;
    }
  }
  return refs;
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
      const [{ inline: inlineJson, redactedFields }, sealedRefs] = await Promise.all([
        collectInlineJson(uid, paths),
        collectSealedRefs(uid, paths, sealedBudget),
      ]);
      domains.push(
        stripUndefinedObject({
          id,
          encryptionTier: paths.encryptionTier,
          inlineJson: Object.keys(inlineJson).length > 0 ? inlineJson : undefined,
          // Honest disclosure of plaintext keys withheld by the seal-aware
          // allowlist (end_to_end/zero_access only).
          redactedFields: redactedFields.length > 0 ? redactedFields : undefined,
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

    return { ok: true, generatedAt: nowISO(), domains, schemaVersion: 2 };
  }),
);
