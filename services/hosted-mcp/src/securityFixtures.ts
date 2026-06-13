/**
 * Deterministic local adversarial fixtures for the hosted MCP.
 *
 * Boots the REAL server (createServer) against a seeded in-memory Firestore +
 * storage so the cross-tenant / revocation / non-entitled / rate-limit /
 * at-rest-sealed proofs run through the actual route + auth + entitlement +
 * cursor + resource code paths — no prod secrets, no live Firestore, no stubs of
 * the isolation logic. Used by both security.live.test.ts (the unit harness) and
 * scripts/prove-hosted-mcp-live.mjs --local (the script the smoke shell calls).
 *
 * The in-memory store mirrors only the Firestore surface the request path
 * touches: doc().get()/.set(), collection().limit().get(), the
 * collection().where().findNearest() vector path (knowledge.ts), and a
 * runTransaction() whose tx.get/tx.set the rate limiter relies on. findNearest
 * brute-forces COSINE exactly like the production index contract — see
 * knowledge.test.ts, which exercises the same shape.
 */

import { generateKeyPairSync } from "node:crypto";
import { MCP_RESOURCE } from "./config.js";
import { mintEd25519Token, type AccessTokenClaims } from "./auth.js";
import { cosineSimilarity, KNOWLEDGE_VECTOR_DIM } from "./knowledgeVector.js";
import type { StorageBodyDownloader } from "./resources.js";

/** A 384-float vector with `lead` set and the rest zeroed (the shim cloaks on device). */
export function vec384(lead: number[]): number[] {
  return [...lead, ...Array(KNOWLEDGE_VECTOR_DIM - lead.length).fill(0)];
}

interface StoredDoc {
  path: string;
  data: Record<string, unknown>;
}

/** Deep-ish clone so reads never alias the stored object the caller might mutate. */
function clone<T>(value: T): T {
  return value === undefined ? value : (JSON.parse(JSON.stringify(value)) as T);
}

/** Resolve `FieldValue.vector(...)`/array query vectors to a plain number[]. */
function toVector(raw: unknown): number[] {
  if (Array.isArray(raw)) return raw.map(Number);
  if (raw && typeof raw === "object") {
    const toArray = Reflect.get(raw, "toArray");
    if (typeof toArray === "function") {
      const out = Reflect.apply(toArray, raw, []);
      if (Array.isArray(out)) return out.map(Number);
    }
    const values = Reflect.get(raw, "_values") ?? Reflect.get(raw, "values");
    if (Array.isArray(values)) return values.map(Number);
  }
  return [];
}

/**
 * Dependency-free in-memory Firestore. Satisfies the HostedMcpFirestore surface
 * AND the knowledge vector-search surface, threaded into createServer({ db }).
 */
export interface InMemoryFirestore {
  doc(path: string): unknown;
  collection(path: string): unknown;
  /** Presence is what isFullFirestore() checks so tools/call accepts this db. */
  collectionGroup(path: string): unknown;
  runTransaction<T>(fn: (tx: unknown) => Promise<T>): Promise<T>;
  /** test/debug only: raw access to seeded docs (used by the at-rest assertion). */
  __docs(): StoredDoc[];
}

export function createInMemoryFirestore(seed: StoredDoc[] = []): InMemoryFirestore {
  const docs = new Map<string, Record<string, unknown>>();
  for (const entry of seed) docs.set(entry.path, entry.data);

  function docRef(path: string) {
    return {
      async get() {
        const data = docs.get(path);
        return {
          exists: data !== undefined,
          id: path.split("/").pop() ?? "",
          data: () => (data === undefined ? undefined : clone(data)),
          get: (field: string) => (data === undefined ? undefined : clone(data[field])),
        };
      },
      async set(value: unknown, options?: { merge?: boolean }) {
        const next = (value ?? {}) as Record<string, unknown>;
        if (options?.merge) docs.set(path, { ...(docs.get(path) ?? {}), ...next });
        else docs.set(path, { ...next });
        return undefined;
      },
    };
  }

  // collection().limit(n).get() / collection().where(...).findNearest(...).get()
  function collectionRef(collectionPath: string) {
    const inCollection = () =>
      [...docs.entries()]
        .filter(([p]) => p.startsWith(`${collectionPath}/`) && !p.slice(collectionPath.length + 1).includes("/"))
        .map(([p, data]) => ({ id: p.split("/").pop() ?? "", data }));

    function vectorQuery(filtered: Array<{ id: string; data: Record<string, unknown> }>) {
      return {
        where(field: string, _op: "==", value: unknown) {
          return vectorQuery(filtered.filter((row) => row.data[field] === value));
        },
        findNearest({
          queryVector,
          limit,
          distanceResultField,
        }: {
          vectorField: string;
          queryVector: unknown;
          limit: number;
          distanceMeasure: "COSINE";
          distanceResultField: string;
        }) {
          const qv = toVector(queryVector);
          const ranked = filtered
            .map((row) => ({ row, sim: cosineSimilarity(qv, (row.data.embedding as number[]) ?? []) }))
            .sort((a, b) => b.sim - a.sim)
            .slice(0, limit);
          return {
            async get() {
              return {
                size: ranked.length,
                docs: ranked.map(({ row, sim }) => ({
                  id: row.id,
                  get: (field: string) =>
                    field === distanceResultField ? 1 - sim : clone(row.data[field]),
                })),
              };
            },
          };
        },
      };
    }

    return {
      // metadata-listing surface (resources.listResources / search facets)
      limit(count: number) {
        return {
          async get() {
            return {
              docs: inCollection()
                .slice(0, count)
                .map(({ id, data }) => ({
                  id,
                  get: (field: string) => clone(data[field]),
                  data: () => clone(data),
                })),
            };
          },
        };
      },
      // vector-search surface (knowledge.searchKnowledge)
      where(field: string, op: "==", value: unknown) {
        return vectorQuery(inCollection()).where(field, op, value);
      },
      findNearest(options: Parameters<ReturnType<typeof vectorQuery>["findNearest"]>[0]) {
        return vectorQuery(inCollection()).findNearest(options);
      },
    };
  }

  return {
    doc: docRef,
    collection: collectionRef,
    // isFullFirestore() only checks that collectionGroup is a function; the
    // hosted-MCP request path never issues a collection-group query, so a
    // throwing stub is enough to let tools/call accept this db.
    collectionGroup() {
      throw new Error("collectionGroup is not used by the hosted MCP request path");
    },
    async runTransaction<T>(fn: (tx: unknown) => Promise<T>): Promise<T> {
      const tx = {
        async get(ref: { get(): Promise<{ get(field: string): unknown }> }) {
          return ref.get();
        },
        set(ref: { set(value: unknown, options?: unknown): Promise<unknown> }, data: unknown, options?: unknown) {
          void ref.set(data, options);
        },
      };
      return fn(tx);
    },
    __docs() {
      return [...docs.entries()].map(([path, data]) => ({ path, data }));
    },
  };
}

/** A sealed at-rest session body — only ciphertext + opaque metadata, NO plaintext. */
export function sealedSessionBody(uid: string, docId: string): string {
  return JSON.stringify({
    signalEnvelopeFormatVersion: 1,
    mode: "at-rest",
    binding: { uid, scope: "cloudvault", collection: "session_logs", docId, field: "body" },
    ciphertextLayer: { payloadCiphertextB64: "c2VhbGVkLXNlc3Npb24tYm9keQ==", payloadAADLabel: "cloudvault:session/body", schemaVersion: 1 },
  });
}

/**
 * Plaintext markers seeded ONLY into the in-memory crypto fixture inputs (never
 * into a stored doc). The at-rest proof asserts none of these reach the wire.
 */
export const PLAINTEXT_MARKERS = ["TENANT_B_PLAINTEXT_SECRET", "TENANT_A_PLAINTEXT_SECRET"] as const;

export interface SeededTenant {
  uid: string;
  clientId: string;
  /** Mints an Ed25519 access token for this tenant with the given scopes (real signing path). */
  token(scopes: string[], overrides?: Partial<AccessTokenClaims>): string;
}

export interface SeededWorld {
  privateKeyBase64: string;
  publicKeyBase64: string;
  db: InMemoryFirestore;
  /** A seeded body downloader for resources/read; serves the sealed body for B's doc only. */
  download: StorageBodyDownloader;
  tenantA: SeededTenant;
  tenantB: SeededTenant;
  /**
   * A dedicated entitled tenant with its OWN conversation doc, used to exhaust
   * the body:standard cap without poisoning tenant B's bucket for the at-rest
   * proof (each adversarial case stays independent).
   */
  tenantRateLimit: SeededTenant;
  /** The vector doc id seeded into tenant B's knowledge memory. */
  vectorIdB: string;
  /** The conversation doc id seeded into tenant B's cloud_search_documents. */
  conversationIdB: string;
  /** The conversation doc id seeded for the rate-limit tenant. */
  conversationIdRateLimit: string;
}

const FAR_FUTURE = () => new Date(Date.now() + 86_400_000).toISOString();

/**
 * Seed two isolated tenants (A and B), an Ed25519 signer, and a resource owned
 * by B. Cloud-Pro entitlement + an active remote_mcp_client grant are seeded for
 * both so the only thing under test in the isolation proof is namespace scoping,
 * not entitlement. A REVOKED client and a NON-entitled tenant are also wired so
 * the revocation + entitlement gates can be exercised end-to-end.
 */
export function seedTwoTenantWorld(): SeededWorld {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const publicKeyBase64 = Buffer.from(publicKey.export({ type: "spki", format: "pem" }).toString(), "utf8").toString("base64");
  const privateKeyBase64 = Buffer.from(privateKey.export({ type: "pkcs8", format: "pem" }).toString(), "utf8").toString("base64");

  const uidA = "tenant-A";
  const uidB = "tenant-B";
  const uidRl = "tenant-rl";
  const vectorIdB = "vec-B-1";
  const conversationIdB = "conv-B-1";
  const conversationIdRl = "conv-rl-1";
  const allScopes = ["search:read", "conversation:read", "usage:read", "index:status", "knowledge:read"];

  const seed: StoredDoc[] = [];
  const entitled = (uid: string) => {
    seed.push({ path: `users/${uid}/entitlements/burnbar_pro`, data: { active: true, expiresAt: FAR_FUTURE() } });
  };
  const activeClient = (uid: string, clientId: string, scopes: string[]) => {
    seed.push({ path: `users/${uid}/remote_mcp_clients/${clientId}`, data: { displayName: clientId, allowedScopes: scopes } });
  };

  // Tenant A: entitled, active client, full scopes — the adversary in the cross-tenant probe.
  entitled(uidA);
  activeClient(uidA, "client-A", allScopes);
  // Tenant B: entitled, active client, AND owns the only seeded resources.
  entitled(uidB);
  activeClient(uidB, "client-B", allScopes);

  // A's own (empty) knowledge namespace stays empty; B owns the sole vector doc.
  seed.push({
    path: `users/${uidB}/cloud_search_knowledge/${vectorIdB}`,
    data: {
      embedding: vec384([1, 0, 0]),
      embeddingModelVersion: "bge-small-en-v1.5",
      dedupHashVersion: 1,
      sourceKind: "notes",
      slugHmac: "b".repeat(64),
      dedupHash: "deadbeefb",
      // Sealed-only at rest. PLAINTEXT_MARKERS[0] never appears here.
      sealedCiphertext: { algorithm: "AES-256-GCM", keyVersion: 1, nonce: "n", ciphertext: "c2VhbGVkLWtub3dsZWRnZQ==", tag: "t" },
      sealedMetadata: { algorithm: "AES-256-GCM", keyVersion: 1, nonce: "n2", ciphertext: "c2VhbGVkLW1ldGE=", tag: "t2" },
    },
  });
  // B's conversation resource (for resources/list + resources/read).
  seed.push({
    path: `users/${uidB}/cloud_search_documents/${conversationIdB}`,
    data: {
      sourceID: "Tenant B Session",
      storagePath: `users/${uidB}/session_logs/${conversationIdB}/bodies/body-0`,
      bodyHash: "bodyhash-B",
    },
  });

  // Dedicated rate-limit tenant: entitled, active client, owns its own body
  // resource so the body:standard cap can be exhausted in isolation.
  entitled(uidRl);
  activeClient(uidRl, "client-rl", allScopes);
  seed.push({
    path: `users/${uidRl}/cloud_search_documents/${conversationIdRl}`,
    data: {
      sourceID: "Rate Limit Session",
      storagePath: `users/${uidRl}/session_logs/${conversationIdRl}/bodies/body-0`,
      bodyHash: "bodyhash-rl",
    },
  });

  // A revoked client for tenant A and a NON-entitled tenant for the deny proofs.
  seed.push({ path: `users/${uidA}/remote_mcp_clients/client-A-revoked`, data: { displayName: "revoked", allowedScopes: allScopes, revokedAt: new Date().toISOString() } });
  const uidFree = "tenant-free";
  activeClient(uidFree, "client-free", allScopes); // active client but NO entitlement doc.

  const db = createInMemoryFirestore(seed);

  // Storage downloader: serves the sealed body for B's (and the rate-limit
  // tenant's) owner-scoped paths only. A's cross-tenant probe never reaches here
  // because readConversationBody scopes the doc lookup to users/A/... (404s).
  const sealedBodies = new Map<string, string>([
    [`users/${uidB}/session_logs/${conversationIdB}/bodies/body-0`, sealedSessionBody(uidB, conversationIdB)],
    [`users/${uidRl}/session_logs/${conversationIdRl}/bodies/body-0`, sealedSessionBody(uidRl, conversationIdRl)],
  ]);
  const download: StorageBodyDownloader = async (storagePath) => {
    const body = sealedBodies.get(storagePath);
    if (body === undefined) throw new Error(`unexpected storage path: ${storagePath}`);
    return Buffer.from(body, "utf8");
  };

  function tenant(uid: string, clientId: string): SeededTenant {
    return {
      uid,
      clientId,
      token(scopes, overrides = {}) {
        const claims: AccessTokenClaims = {
          sub: uid,
          aud: MCP_RESOURCE,
          client_id: clientId,
          scopes,
          entitlement_family: "burnbar_pro",
          grant_mode: "local_decrypt_shim",
          exp: Math.floor(Date.now() / 1000) + 600,
          jti: `jti-${uid}-${Math.random().toString(36).slice(2, 10)}`,
          ...overrides,
        };
        return mintEd25519Token(claims, privateKeyBase64);
      },
    };
  }

  return {
    privateKeyBase64,
    publicKeyBase64,
    db,
    download,
    tenantA: tenant(uidA, "client-A"),
    tenantB: tenant(uidB, "client-B"),
    tenantRateLimit: tenant(uidRl, "client-rl"),
    vectorIdB,
    conversationIdB,
    conversationIdRateLimit: conversationIdRl,
  };
}
