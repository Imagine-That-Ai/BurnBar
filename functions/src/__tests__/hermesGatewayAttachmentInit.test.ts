/**
 * Hermes Gateway /attachments/init hardening (security finding P2#8).
 *
 * Two asymmetries are closed here:
 *   1. ID CAP SYMMETRY — init used `safeIdentifier` (no length cap, lossy charset
 *      coercion) while /attachments/finalize uses `requiredHttpIdentifier` (≤160,
 *      [A-Za-z0-9_.:-]). So init could adopt an id finalize would later reject.
 *      `adoptedGatewayDocId` now adopts a client id ONLY when it would also pass
 *      the canonical finalize contract; anything over-long / out-of-charset /
 *      absent falls back to a fresh server-minted token. These unit tests assert
 *      that EVERY id init adopts is an id `requiredHttpIdentifier` accepts.
 *   2. NO BLIND CLOBBER — init used `set(merge:false)`, so a re-init of the same
 *      attachmentId silently re-minted a fresh signed upload URL over an existing
 *      manifest. init now does a create-if-absent transaction: a re-init of an
 *      existing id returns 409, while the first init→finalize happy path is
 *      unchanged. The integration block drives the real `burnBarHermesGateway`
 *      onRequest end-to-end over an in-memory Firestore double (mirrors the
 *      harness in hermesGatewaySealedEvent.test.ts).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { hashHermesGatewayBearerToken } from "../hermesGateway.js";

// All imports of ../callables/hermesGateway.js are LAZY (await import inside a
// test) so the vi.mock factories below (which capture the in-memory doubles) are
// fully initialized before the module — and its `import { db } from
// "../adminRuntime.js"` — first evaluates.

// ---------------------------------------------------------------------------
// Integration mocks: drive the real burnBarHermesGateway onRequest over an
// in-memory Firestore + Storage double. Proves create-if-absent (409 on re-init)
// and that the happy path init→finalize still works (finding P2#8 fix 2).
// ---------------------------------------------------------------------------
vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));

// Real validators, but force the three entitlement predicates the gateway gate
// consults so the call runs without seeded entitlement docs.
vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return {
    ...actual,
    isActiveHostedQuotaEntitlement: () => true,
    isActivePremiumEntitlement: () => true,
    isActiveBurnBarCloudProEntitlement: () => true,
  };
});

vi.mock("firebase-admin/firestore", () => ({
  FieldValue: { delete: () => ({ __delete: true }) },
  Timestamp: {
    now: () => ({ __ts: true, toMillis: () => Date.now() }),
    fromMillis: (ms: number) => ({ __ts: true, toMillis: () => ms }),
  },
}));

// Storage double: getStorage().bucket().file(path).getSignedUrl(opts) -> [url].
// Each call returns a URL that embeds the storage path so a re-init that DID
// clobber would be observable as a fresh, different URL.
let signedUrlCounter = 0;
vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({
    bucket: () => ({
      file: (path: string) => ({
        getSignedUrl: async () => [`https://signed.example/${path}?n=${++signedUrlCounter}`],
      }),
    }),
  }),
}));

// In-memory Firestore double keyed by full doc path, with the transaction surface
// (runTransaction + tx.get/tx.set) the hardened init/finalize/message paths use.
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
    };
    return fn(tx);
  },
};

vi.mock("../adminRuntime.js", () => ({ db: dbMock, auth: {} }));

process.env.ENFORCE_APP_CHECK = "false";

const UID = "userAtt";
const CLIENT_ID = "hgw_attach_client";
const TOKEN = "obb_hgw_test_token_attachments";
const TOKEN_HASH = hashHermesGatewayBearerToken(TOKEN);

function seedGrant(): void {
  stored.set(`hermes_gateway_token_index/${TOKEN_HASH}`, { uid: UID, clientId: CLIENT_ID });
  stored.set(`users/${UID}/hermes_gateway_clients/${CLIENT_ID}`, {
    id: CLIENT_ID,
    uid: UID,
    displayName: "Hermes Agent",
    status: "active",
    tokenHash: TOKEN_HASH,
    tokenPreview: "obb_hgw_...oken",
    scopes: ["hermes.gateway.read", "hermes.gateway.write"],
    homeDestinationId: "burnbar:home",
    relayCapable: true,
    createdAt: "2026-06-01T00:00:00.000Z",
    updatedAt: "2026-06-01T00:00:00.000Z",
    schemaVersion: 2,
  });
}

// A v2 relay envelope: the sealed init path (relayCapable client cannot send a
// plaintext fileName, so the envelope carries the sealed name).
const SENDER_PUBKEY_B64 = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 9)]).toString("base64");
function sealedEnvelope() {
  return {
    payloadCiphertext: Buffer.from("sealed-name-bytes").toString("base64"),
    wrappedKey: Buffer.from("wrapped-attachment-key").toString("base64"),
    relayEncryption: "p256-hkdf-sha256-aesgcm",
    relayKeyVersion: 2,
    senderPublicKey: SENDER_PUBKEY_B64,
  };
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
  const headers: Record<string, string> = { authorization: `Bearer ${TOKEN}` };
  return {
    method: "POST",
    path,
    url: path,
    body,
    headers: { ...headers },
    query: {},
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
  expect(value, `${label} must be an object`).toEqual(expect.any(Object));
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return Object.fromEntries(Object.entries(value));
}

function stringField(value: unknown, key: string): string {
  const out = record(value)[key];
  if (typeof out !== "string") throw new Error(`${key} must be a string`);
  return out;
}

// The canonical id cap (mirrors HERMES_GATEWAY_HTTP_ID_MAX_LENGTH in the module;
// inlined here so the integration block needs no lazy import just for a constant).
const ID_CAP = 160;

async function callGateway(path: string, body: Record<string, unknown>): Promise<CapturedResponse> {
  // Drive the inner dispatcher (no onRequest/CORS plumbing) — the exact seam
  // production calls; the wrapped burnBarHermesGateway only adds CORS middleware.
  const { dispatchHermesGatewayRequest } = await import("../callables/hermesGateway.js");
  const { res, captured } = makeRes();
  await dispatchHermesGatewayRequest(makeReq(path, body), res);
  return captured;
}

describe("/attachments/init — create-if-absent hardening (finding P2#8 fix 2)", () => {
  beforeEach(() => {
    stored.clear();
    signedUrlCounter = 0;
    seedGrant();
  });
  afterEach(() => vi.clearAllMocks());

  it("inits a fresh sealed attachment, mints an upload URL, and stores the manifest", async () => {
    const res = await callGateway("/attachments/init", {
      attachmentId: "att_happy_path_0001",
      relayEnvelope: sealedEnvelope(),
      byteCount: 1024,
    });
    expect(res.status).toBe(200);
    const body = record(res.body, "init response body");
    expect(typeof body.uploadURL).toBe("string");
    const manifest = record(body.attachment, "attachment manifest");
    expect(manifest.id).toBe("att_happy_path_0001");
    expect(manifest.status).toBe("pending_upload");
    expect(manifest.clientId).toBe(CLIENT_ID);
    expect(manifest.relayEnvelope).toEqual(sealedEnvelope());
    // The doc was persisted at the per-client-namespaced storage path.
    expect(manifest.storagePath).toBe(`users/${UID}/hermes_gateway_attachments/${CLIENT_ID}/att_happy_path_0001`);
    expect(stored.has(`users/${UID}/hermes_gateway_attachments/att_happy_path_0001`)).toBe(true);
  });

  it("REJECTS a second init of the same attachmentId with 409 and does NOT re-mint the URL", async () => {
    const first = await callGateway("/attachments/init", {
      attachmentId: "att_dup_0002",
      relayEnvelope: sealedEnvelope(),
      byteCount: 2048,
    });
    expect(first.status).toBe(200);
    const firstURL = record(first.body, "first init response body").uploadURL;
    const firstManifest = { ...stored.get(`users/${UID}/hermes_gateway_attachments/att_dup_0002`) };

    const second = await callGateway("/attachments/init", {
      attachmentId: "att_dup_0002",
      relayEnvelope: sealedEnvelope(),
      byteCount: 4096, // different byteCount: prove a clobber would have been observable
    });
    expect(second.status).toBe(409);
    expect(record(second.body, "second init response body").error).toBe("attachment_already_initialized");

    // The stored manifest is untouched by the rejected re-init (no clobber).
    const afterManifest = stored.get(`users/${UID}/hermes_gateway_attachments/att_dup_0002`);
    expect(afterManifest).toEqual(firstManifest);
    expect(afterManifest?.byteCount).toBe(2048);
    // The first URL remains the only minted URL for this id.
    expect(record(second.body, "second init response body").uploadURL).toBeUndefined();
    expect(typeof firstURL).toBe("string");
  });

  it("rejects an over-long attachmentId consistently with finalize (init falls back, finalize 404s the over-long id)", async () => {
    const overLong = "a".repeat(ID_CAP + 1);
    const initRes = await callGateway("/attachments/init", {
      attachmentId: overLong,
      relayEnvelope: sealedEnvelope(),
      byteCount: 512,
    });
    // init did not adopt the over-long id; it minted a fresh att_<hex> instead.
    expect(initRes.status).toBe(200);
    const manifest = record(record(initRes.body, "init response body").attachment, "attachment manifest");
    expect(manifest.id).not.toBe(overLong);
    expect(stringField(manifest, "id")).toMatch(/^att_[0-9a-f]{16}$/);
    // And no doc was ever written under the over-long key.
    expect(stored.has(`users/${UID}/hermes_gateway_attachments/${overLong}`)).toBe(false);

    // Symmetry check: handing the over-long id to finalize is a hard 400 (the
    // canonical validator rejects it via boundedTrimmedString's length cap) — init
    // could never have produced a manifest finalize would then be unable to
    // address. The rejection code is the length-cap error from requiredHttpIdentifier.
    const finalizeRes = await callGateway("/attachments/finalize", { attachmentId: overLong });
    expect(finalizeRes.status).toBe(400);
    expect(record(finalizeRes.body, "finalize response body").error).toBe("invalid-argument");
  });

  it("happy path: init then finalize the SAME minted attachment succeeds", async () => {
    const initRes = await callGateway("/attachments/init", {
      attachmentId: "att_finalize_0003",
      relayEnvelope: sealedEnvelope(),
      byteCount: 3072,
    });
    expect(initRes.status).toBe(200);
    const attachmentId = stringField(
      record(record(initRes.body, "init response body").attachment, "attachment manifest"),
      "id",
    );
    expect(attachmentId).toBe("att_finalize_0003");

    // Simulate the upload having completed: flip the manifest to uploaded so
    // finalize's idempotent "already uploaded" branch confirms the same doc.
    const manifestPath = `users/${UID}/hermes_gateway_attachments/${attachmentId}`;
    stored.set(manifestPath, { ...stored.get(manifestPath), status: "uploaded" });

    const finalizeRes = await callGateway("/attachments/finalize", { attachmentId });
    // finalize resolves the manifest by id (no 404 / no validation mismatch).
    expect(finalizeRes.status).toBe(200);
    const finalManifest = record(record(finalizeRes.body, "finalize response body").attachment, "attachment manifest");
    expect(finalManifest.id).toBe(attachmentId);
    expect(finalManifest.status).toBe("uploaded");
  });
});

// ---------------------------------------------------------------------------
// Unit: id-cap symmetry (finding P2#8 fix 1). adoptedGatewayDocId +
// requiredHttpIdentifier are pure; loaded lazily (the module is mock-wired
// above, but these helpers touch neither Firestore nor Storage). The invariant:
// anything adoptedGatewayDocId returns from a CLIENT id (i.e. without falling
// back) must pass requiredHttpIdentifier unchanged.
// ---------------------------------------------------------------------------
describe("adoptedGatewayDocId — init↔finalize id symmetry", () => {
  const FALLBACK = "att_deadbeefdeadbeef";
  const fallback = () => FALLBACK;

  it("adopts a well-formed client id and that id passes the finalize validator", async () => {
    const { adoptedGatewayDocId, requiredHttpIdentifier } = await import("../callables/hermesGateway.js");
    const clientId = "att_1234567890abcdef";
    const adopted = adoptedGatewayDocId(clientId, fallback);
    expect(adopted).toBe(clientId);
    // The canonical finalize contract must accept exactly what init adopted.
    expect(requiredHttpIdentifier(adopted, "attachmentId")).toBe(clientId);
  });

  it("adopts the full canonical charset (letters, digits, _ . : -) verbatim", async () => {
    const { adoptedGatewayDocId, requiredHttpIdentifier } = await import("../callables/hermesGateway.js");
    const clientId = "Att.0-9_x:Y";
    const adopted = adoptedGatewayDocId(clientId, fallback);
    expect(adopted).toBe(clientId);
    expect(requiredHttpIdentifier(adopted, "attachmentId")).toBe(clientId);
  });

  it("falls back (does NOT clamp) when the client id exceeds the finalize cap", async () => {
    const { adoptedGatewayDocId, requiredHttpIdentifier, HERMES_GATEWAY_HTTP_ID_MAX_LENGTH } =
      await import("../callables/hermesGateway.js");
    const overLong = "a".repeat(HERMES_GATEWAY_HTTP_ID_MAX_LENGTH + 1);
    // requiredHttpIdentifier would reject the over-long id outright...
    expect(() => requiredHttpIdentifier(overLong, "attachmentId")).toThrow();
    // ...so init must NOT adopt it; it mints a fresh id that finalize accepts.
    const adopted = adoptedGatewayDocId(overLong, fallback);
    expect(adopted).toBe(FALLBACK);
    expect(requiredHttpIdentifier(adopted, "attachmentId")).toBe(FALLBACK);
  });

  it("adopts an id at exactly the cap length", async () => {
    const { adoptedGatewayDocId, requiredHttpIdentifier, HERMES_GATEWAY_HTTP_ID_MAX_LENGTH } =
      await import("../callables/hermesGateway.js");
    const atCap = "a".repeat(HERMES_GATEWAY_HTTP_ID_MAX_LENGTH);
    const adopted = adoptedGatewayDocId(atCap, fallback);
    expect(adopted).toBe(atCap);
    expect(requiredHttpIdentifier(adopted, "attachmentId")).toBe(atCap);
  });

  it("falls back for out-of-charset, whitespace-only, empty, and non-string ids", async () => {
    const { adoptedGatewayDocId } = await import("../callables/hermesGateway.js");
    // Each of these is rejected by the canonical charset / non-string guard, so
    // init mints a fresh id instead. (Note: "." and ".." ARE in the canonical
    // charset and are adopted verbatim — finalize accepts them too, so the rule
    // stays symmetric; they are intentionally not in this fall-back list.)
    for (const bad of [
      "has spaces",
      "slash/inside",
      "emoji😀",
      "   ",
      "",
      "a/b",
      "back\\slash",
      42,
      null,
      undefined,
      {},
    ]) {
      expect(adoptedGatewayDocId(bad, fallback)).toBe(FALLBACK);
    }
  });

  it("trims surrounding whitespace before adopting (matches boundedTrimmedString)", async () => {
    const { adoptedGatewayDocId, requiredHttpIdentifier } = await import("../callables/hermesGateway.js");
    const adopted = adoptedGatewayDocId("  att_padded  ", fallback);
    expect(adopted).toBe("att_padded");
    expect(requiredHttpIdentifier(adopted, "attachmentId")).toBe("att_padded");
  });
});
