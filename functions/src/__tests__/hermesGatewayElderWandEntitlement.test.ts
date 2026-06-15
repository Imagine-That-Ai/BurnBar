/**
 * The Elder Wand — server-side entitlement gate (Phase 4).
 *
 * The Elder Wand (wire-compatible plugin id `"fusion"`) is BurnBar's
 * multi-model analysis router. The functions gateway is the RELAY control-plane:
 * it is where BurnBar authorizes a relayed/hosted chat-completions forward. When
 * such a forward carries an ACTIVE fusion plugin block, the relay write path
 * (`/messages`) must additionally require Cloud Pro ("Pro Max") via
 * `assertActiveBurnBarCloudProEntitlement`, returning 403
 * `{ error:"entitlement_required", requiredTier:"pro", feature:"elderWand" }`
 * through the existing httpError -> sendJSON writer BEFORE any persistence/spend.
 *
 * HONESTY: a purely-local daemon fusion run over the user's OWN provider keys is
 * licensing-gated client-side and is NOT cryptographically bypass-proof on a Mac
 * the user controls. This seam covers the relay/hosted spend path — the real
 * credit-protection boundary — and proves: (1) a non-Pro caller is rejected with
 * the structured 403 and writes NOTHING downstream; (2) a Pro caller proceeds and
 * the relay message is persisted; (3) a non-fusion forward is never Pro-gated.
 *
 * The harness drives the real `dispatchHermesGatewayRequest` over an in-memory
 * Firestore double (mirrors hermesGatewayAttachmentInit.test.ts) so it exercises
 * the production seam, not a re-implementation of the gate.
 */
import { createHash, generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { hashHermesGatewayBearerToken } from "../hermesGateway.js";

// All imports of ../callables/hermesGateway.js are LAZY (await import inside a
// test) so the vi.mock factories below are fully initialized before the module —
// and its `import { db } from "../adminRuntime.js"` — first evaluates.

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));

// Controls which uid `assertActiveBurnBarCloudProEntitlement` accepts. The base
// gateway entitlement is forced true for every uid (so both the Pro and non-Pro
// callers reach the relay write path), while Cloud Pro is gated ONLY through the
// real assert seam the production code calls — switched per test by uid.
const PRO_UIDS = new Set<string>();

vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return {
    ...actual,
    // Base Hermes Gateway entitlement: pass for everyone so the request is not
    // rejected before the Elder Wand gate runs.
    isActiveHostedQuotaEntitlement: () => true,
    isActivePremiumEntitlement: () => true,
    isActiveBurnBarCloudProEntitlement: () => true,
    // The Cloud Pro assertion the Elder Wand gate calls. Reject any uid not in
    // PRO_UIDS exactly as the real assert would (permission-denied HttpsError),
    // so the gate's structured-403 conversion is exercised end-to-end.
    assertActiveBurnBarCloudProEntitlement: vi.fn(async (uid: string): Promise<void> => {
      if (!PRO_UIDS.has(uid)) {
        const { HttpsError } = await import("firebase-functions/v2/https");
        throw new HttpsError("permission-denied", "BurnBar Cloud Pro is required for Floo and hosted Agent Control.");
      }
    }),
  };
});

vi.mock("firebase-admin/firestore", () => ({
  FieldValue: { delete: () => ({ __delete: true }) },
  Timestamp: {
    now: () => ({ __ts: true, toMillis: () => Date.now() }),
    fromMillis: (ms: number) => ({ __ts: true, toMillis: () => ms }),
  },
}));

vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({
    bucket: () => ({
      file: () => ({
        exists: async () => [false],
        getSignedUrl: async () => ["https://signed.example/unused"],
      }),
    }),
  }),
}));

// In-memory Firestore double keyed by full doc path, with the transaction
// surface (runTransaction + tx.get/tx.set/tx.create) the relay write uses.
const stored = new Map<string, Record<string, unknown>>();

function snapFor(path: string) {
  return {
    id: path.split("/").pop(),
    exists: stored.has(path),
    data: () => stored.get(path),
    get: (field: string) => stored.get(path)?.[field],
  };
}

function docRef(path: string) {
  return {
    __path: path,
    get: async () => snapFor(path),
    set: async (data: Record<string, unknown>) => void stored.set(path, { ...stored.get(path), ...data }),
    delete: async () => void stored.delete(path),
  };
}

const dbMock = {
  doc: (path: string) => docRef(path),
  collection: () => ({ doc: (id: string) => docRef(id), get: async () => ({ docs: [], empty: true }) }),
  runTransaction: async (fn: (tx: unknown) => Promise<unknown>) => {
    const tx = {
      get: async (ref: { __path: string }) => snapFor(ref.__path),
      set: (ref: { __path: string }, data: Record<string, unknown>) => {
        stored.set(ref.__path, { ...stored.get(ref.__path), ...data });
      },
      create: (ref: { __path: string }, data: Record<string, unknown>) => {
        if (stored.has(ref.__path)) {
          throw new Error(`Document already exists: ${ref.__path}`);
        }
        stored.set(ref.__path, { ...data });
      },
    };
    return fn(tx);
  },
};

vi.mock("../adminRuntime.js", () => ({ db: dbMock, auth: {} }));

process.env.ENFORCE_APP_CHECK = "false";

const PRO_UID = "userElderWandPro";
const FREE_UID = "userElderWandFree";
const CLIENT_ID = "hgw_elder_wand_client";
const TOKEN = "obb_hgw_test_token_elder_wand";
const TOKEN_HASH = hashHermesGatewayBearerToken(TOKEN);
const { publicKey: AGENT_SIGNING_PUBLIC_KEY, privateKey: AGENT_SIGNING_PRIVATE_KEY } = generateKeyPairSync("ed25519");
const AGENT_SIGNING_PUBLIC_KEY_BASE64 = exportedSpkiDer(AGENT_SIGNING_PUBLIC_KEY).subarray(-32).toString("base64");
const AGENT_SIGNING_KEY_ID = createHash("sha256").update(AGENT_SIGNING_PUBLIC_KEY_BASE64).digest("hex").slice(0, 32);
let popNonceCounter = 0;

// A v2 relay envelope: the relayCapable relay write forwards an opaque sealed
// body. The TOP-LEVEL `plugins` block (the fusion routing hint) is NOT sealed —
// the gate reads only it, never this ciphertext.
const SENDER_PUBKEY_B64 = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 9)]).toString("base64");
function sealedEnvelope() {
  return {
    payloadCiphertext: Buffer.from("sealed-chat-body").toString("base64"),
    wrappedKey: Buffer.from("wrapped-message-key").toString("base64"),
    relayEncryption: "p256-hkdf-sha256-aesgcm",
    relayKeyVersion: 2,
    senderPublicKey: SENDER_PUBKEY_B64,
  };
}

function exportedSpkiDer(key: KeyObject): Buffer {
  const exported = key.export({ format: "der", type: "spki" });
  if (typeof exported === "string") {
    throw new TypeError("Expected DER public key export to be bytes");
  }
  return exported;
}

function stableJSONString(value: unknown): string {
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(stableJSONString).join(",")}]`;
  }
  if (!value || typeof value !== "object") return "{}";
  return `{${Object.entries(value as Record<string, unknown>)
    .filter(([, item]) => item !== undefined)
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, item]) => `${JSON.stringify(key)}:${stableJSONString(item)}`)
    .join(",")}}`;
}

function popHeaders(method: string, path: string, body: Record<string, unknown>): Record<string, string> {
  const timestamp = new Date().toISOString();
  const nonce = `elder-wand-pop-nonce-${++popNonceCounter}`;
  const bodyHash = createHash("sha256").update(stableJSONString(body)).digest("hex");
  const payload = Buffer.from(
    ["OpenBurnBar.HermesGatewayPoP.v1", TOKEN_HASH, method.toUpperCase(), path, bodyHash, nonce, timestamp].join("\n"),
    "utf8",
  );
  return {
    "x-openburnbar-pop-nonce": nonce,
    "x-openburnbar-pop-timestamp": timestamp,
    "x-openburnbar-pop-body-sha256": bodyHash,
    "x-openburnbar-pop-signature-ed25519": sign(null, payload, AGENT_SIGNING_PRIVATE_KEY).toString("base64"),
  };
}

function seedGrant(uid: string): void {
  stored.set(`hermes_gateway_token_index/${TOKEN_HASH}`, { uid, clientId: CLIENT_ID });
  stored.set(`users/${uid}/hermes_gateway_clients/${CLIENT_ID}`, {
    id: CLIENT_ID,
    uid,
    displayName: "Hermes Agent",
    status: "active",
    tokenHash: TOKEN_HASH,
    tokenPreview: "obb_hgw_...wand",
    scopes: ["hermes.gateway.read", "hermes.gateway.write"],
    homeDestinationId: "burnbar:home",
    relayCapable: true,
    agentClientSigningPublicKeyBase64: AGENT_SIGNING_PUBLIC_KEY_BASE64,
    agentClientSigningKeyId: AGENT_SIGNING_KEY_ID,
    popRequired: true,
    expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
    createdAt: "2026-06-01T00:00:00.000Z",
    updatedAt: "2026-06-01T00:00:00.000Z",
    schemaVersion: 2,
  });
}

interface CapturedResponse {
  status: number;
  body: unknown;
}

interface TestHttpResponse {
  status(code: number): TestHttpResponse;
  json(payload: unknown): void;
  send(payload?: unknown): void;
  set(name: string, value: string): void;
}

function makeReq(path: string, body: Record<string, unknown>) {
  const headers: Record<string, string> = {
    authorization: `Bearer ${TOKEN}`,
    "content-type": "application/json",
    ...popHeaders("POST", path, body),
  };
  return {
    method: "POST",
    path,
    url: path,
    body,
    headers: { ...headers },
    query: {},
    socket: { remoteAddress: "127.0.0.1" },
    get: (name: string) => headers[name.toLowerCase()],
  };
}

function makeRes(): { res: TestHttpResponse; captured: CapturedResponse } {
  const captured: CapturedResponse = { status: 0, body: undefined };
  const res: TestHttpResponse = {
    status(code: number) {
      captured.status = code;
      return res;
    },
    json(payload: unknown) {
      captured.body = payload;
    },
    send(payload?: unknown) {
      captured.body = payload;
    },
    set() {
      /* headers ignored in tests */
    },
  };
  return { res, captured };
}

function record(value: unknown, label = "value"): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return Object.fromEntries(Object.entries(value));
}

async function callGateway(path: string, body: Record<string, unknown>): Promise<CapturedResponse> {
  // Drive the inner dispatcher (no onRequest/CORS plumbing) — the exact seam
  // production calls.
  const { dispatchHermesGatewayRequest } = await import("../callables/hermesGateway.js");
  const { res, captured } = makeRes();
  await dispatchHermesGatewayRequest(makeReq(path, body), res);
  return captured;
}

// A forwarded chat-completions relay write carrying the OpenRouter-Fusion-shaped
// plugin block alongside the sealed body. messageId is freshly minted per call
// so a 200 happy path stores a NEW doc (token_hex(16)-shaped, echoed verbatim).
let messageCounter = 0;
function fusionMessageBody(extra: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    messageId: createHash("sha256").update(`elder-wand-msg-${++messageCounter}`).digest("hex").slice(0, 32),
    relayEnvelope: sealedEnvelope(),
    plugins: [
      {
        id: "fusion",
        enabled: true,
        analysis_models: ["anthropic/claude", "ollama-cloud/model"],
        model: "anthropic/judge",
        max_tool_calls: 8,
      },
    ],
    ...extra,
  };
}

describe("Hermes Gateway relay — Elder Wand (fusion) entitlement gate", () => {
  beforeEach(() => {
    stored.clear();
    PRO_UIDS.clear();
    popNonceCounter = 0;
    messageCounter = 0;
  });
  afterEach(() => vi.clearAllMocks());

  it("REJECTS a non-Pro fusion forward with 403 entitlement_required and writes NOTHING downstream", async () => {
    seedGrant(FREE_UID);
    // FREE_UID is absent from PRO_UIDS -> assertActiveBurnBarCloudProEntitlement throws.

    const res = await callGateway("/messages", fusionMessageBody());

    expect(res.status).toBe(403);
    const body = record(res.body, "403 response body");
    expect(body.error).toBe("entitlement_required");
    expect(body.requiredTier).toBe("pro");
    expect(body.feature).toBe("elderWand");

    // No relay message was persisted — the gate ran before any spend/forward.
    const messageDocs = [...stored.keys()].filter((key) =>
      key.startsWith(`users/${FREE_UID}/hermes_gateway_messages/`),
    );
    expect(messageDocs).toEqual([]);
  });

  it("LETS a Pro (active burnbar_pro_max) fusion forward proceed and persists the relay message", async () => {
    seedGrant(PRO_UID);
    PRO_UIDS.add(PRO_UID); // assertActiveBurnBarCloudProEntitlement resolves.

    const res = await callGateway("/messages", fusionMessageBody());

    expect(res.status).toBe(200);
    const body = record(res.body, "200 response body");
    const message = record(body.message, "persisted relay message");
    expect(message.clientId).toBe(CLIENT_ID);
    expect(message.kind).toBe("agent_message");
    expect(message.relayEnvelope).toEqual(sealedEnvelope());

    // The relay message was actually persisted (the forward proceeded).
    const messageDocs = [...stored.keys()].filter((key) =>
      key.startsWith(`users/${PRO_UID}/hermes_gateway_messages/`),
    );
    expect(messageDocs).toHaveLength(1);
  });

  it("does NOT Pro-gate a NON-fusion relay forward (no plugins block) for a non-Pro caller", async () => {
    seedGrant(FREE_UID); // not in PRO_UIDS

    // Same relay write WITHOUT the fusion plugin block: the Elder Wand gate must
    // not engage, so a base-entitled caller proceeds normally.
    const res = await callGateway("/messages", {
      messageId: createHash("sha256").update("non-fusion-msg").digest("hex").slice(0, 32),
      relayEnvelope: sealedEnvelope(),
    });

    expect(res.status).toBe(200);
    const messageDocs = [...stored.keys()].filter((key) =>
      key.startsWith(`users/${FREE_UID}/hermes_gateway_messages/`),
    );
    expect(messageDocs).toHaveLength(1);
  });

  it("treats an EXPLICITLY disabled fusion plugin (enabled:false) as non-fusion — not Pro-gated", async () => {
    seedGrant(FREE_UID); // not in PRO_UIDS

    const res = await callGateway(
      "/messages",
      fusionMessageBody({
        plugins: [
          {
            id: "fusion",
            enabled: false, // one-request bypass: must NOT trigger the gate
            analysis_models: ["anthropic/claude"],
            model: "anthropic/judge",
          },
        ],
      }),
    );

    expect(res.status).toBe(200);
    const messageDocs = [...stored.keys()].filter((key) =>
      key.startsWith(`users/${FREE_UID}/hermes_gateway_messages/`),
    );
    expect(messageDocs).toHaveLength(1);
  });
});
