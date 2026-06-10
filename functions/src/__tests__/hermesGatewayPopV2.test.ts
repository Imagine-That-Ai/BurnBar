/**
 * L2 — fold the query string into the gateway PoP signed payload (PoP v2).
 *
 * Drives the real dispatcher for GET /events (a query-bearing endpoint) over an
 * in-memory Firestore double, proving:
 *  - a PoP v2 signature that binds the canonical query string is accepted;
 *  - tampering with a query param after signing is caught (bad_pop_signature),
 *    i.e. the query is now integrity-protected (the v1 gap);
 *  - a legacy PoP v1 signature is still accepted during the transition window;
 *  - once a client registers v2 capability (popVersion>=2) a v1 downgrade is
 *    refused (pop_v2_required).
 */
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { hashHermesGatewayBearerToken } from "../hermesGateway.js";

vi.mock("firebase-functions/logger", () => ({ info: vi.fn(), error: vi.fn(), warn: vi.fn(), debug: vi.fn() }));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));
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
  Timestamp: { now: () => ({ __ts: true, toMillis: () => Date.now() }), fromMillis: (ms: number) => ({ __ts: true, toMillis: () => ms }) },
}));

const stored = new Map<string, Record<string, unknown>>();
function snapFor(path: string) {
  return { id: path.split("/").pop(), exists: stored.has(path), data: () => stored.get(path), get: (f: string) => stored.get(path)?.[f] };
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
  collection: (collectionPath: string) => ({
    doc: (id: string) => docRef(`${collectionPath}/${id}`),
    where() {
      return this;
    },
    orderBy() {
      return this;
    },
    limit() {
      return this;
    },
    get: async () => ({ docs: [], empty: true }),
  }),
  runTransaction: async (fn: (tx: unknown) => Promise<unknown>) => {
    const tx = {
      get: async (ref: { __path: string }) => snapFor(ref.__path),
      set: (ref: { __path: string }, data: Record<string, unknown>) => void stored.set(ref.__path, { ...stored.get(ref.__path), ...data }),
      create: (ref: { __path: string }, data: Record<string, unknown>) => {
        if (stored.has(ref.__path)) throw new Error(`Document already exists: ${ref.__path}`);
        stored.set(ref.__path, { ...data });
      },
    };
    return fn(tx);
  },
};
vi.mock("../adminRuntime.js", () => ({ db: dbMock, auth: {} }));

process.env.ENFORCE_APP_CHECK = "false";

const UID = "userPopV2";
const CLIENT_ID = "hgw_popv2_client";
const TOKEN = "obb_hgw_test_token_popv2";
const TOKEN_HASH = hashHermesGatewayBearerToken(TOKEN);
const { publicKey: PUB, privateKey: PRIV } = generateKeyPairSync("ed25519");
const PUB_B64 = Buffer.from(PUB.export({ format: "der", type: "spki" })).subarray(-32).toString("base64");
const KEY_ID = createHash("sha256").update(PUB_B64).digest("hex").slice(0, 32);
let nonceCounter = 0;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stableJSONString(value: unknown): string {
  if (value === null || typeof value === "string" || typeof value === "number" || typeof value === "boolean") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableJSONString).join(",")}]`;
  if (!isRecord(value)) return "{}";
  return `{${Object.entries(value)
    .filter(([, item]) => item !== undefined)
    .sort(([l], [r]) => l.localeCompare(r))
    .map(([k, item]) => `${JSON.stringify(k)}:${stableJSONString(item)}`)
    .join(",")}}`;
}

function canonicalQuery(query: Record<string, unknown>): string {
  const pairs: Array<[string, string]> = [];
  for (const [k, v] of Object.entries(query)) {
    if (Array.isArray(v)) for (const item of v) pairs.push([k, String(item)]);
    else if (v !== undefined && v !== null) pairs.push([k, String(v)]);
  }
  pairs.sort((a, b) => (a[0] === b[0] ? (a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0) : a[0] < b[0] ? -1 : 1));
  return pairs.map(([k, v]) => `${k}=${v}`).join("&");
}

/** Sign the PoP payload. `signedQuery` lets a test sign over a DIFFERENT query
 *  than the request will carry (the tamper case). */
function popHeaders(opts: {
  version: 1 | 2;
  method: string;
  path: string;
  query: Record<string, unknown>;
  signedQuery?: Record<string, unknown>;
  body: Record<string, unknown>;
}): Record<string, string> {
  const timestamp = new Date().toISOString();
  const nonce = `popv2-nonce-${String(++nonceCounter).padStart(8, "0")}`;
  const bodyHash = createHash("sha256").update(stableJSONString(opts.body)).digest("hex");
  const lines =
    opts.version === 2
      ? [
          "OpenBurnBar.HermesGatewayPoP.v2",
          TOKEN_HASH,
          opts.method.toUpperCase(),
          opts.path,
          canonicalQuery(opts.signedQuery ?? opts.query),
          bodyHash,
          nonce,
          timestamp,
        ]
      : ["OpenBurnBar.HermesGatewayPoP.v1", TOKEN_HASH, opts.method.toUpperCase(), opts.path, bodyHash, nonce, timestamp];
  const payload = Buffer.from(lines.join("\n"), "utf8");
  const headers: Record<string, string> = {
    "x-openburnbar-pop-nonce": nonce,
    "x-openburnbar-pop-timestamp": timestamp,
    "x-openburnbar-pop-body-sha256": bodyHash,
    "x-openburnbar-pop-signature-ed25519": sign(null, payload, PRIV).toString("base64"),
  };
  if (opts.version === 2) headers["x-openburnbar-pop-version"] = "2";
  return headers;
}

function seedGrant(popVersion?: number): void {
  stored.set(`hermes_gateway_token_index/${TOKEN_HASH}`, { uid: UID, clientId: CLIENT_ID });
  stored.set(`users/${UID}/hermes_gateway_clients/${CLIENT_ID}`, {
    id: CLIENT_ID,
    uid: UID,
    displayName: "Hermes Agent",
    status: "active",
    tokenHash: TOKEN_HASH,
    tokenPreview: "obb_hgw_...v2",
    scopes: ["hermes.gateway.read", "hermes.gateway.write"],
    homeDestinationId: "burnbar:home",
    agentClientSigningPublicKeyBase64: PUB_B64,
    agentClientSigningKeyId: KEY_ID,
    popRequired: true,
    ...(popVersion !== undefined ? { popVersion } : {}),
    expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
    createdAt: "2026-06-01T00:00:00.000Z",
    updatedAt: "2026-06-01T00:00:00.000Z",
    schemaVersion: 2,
  });
}

interface Captured {
  status: number;
  body: unknown;
}
function makeRes(): { res: unknown; captured: Captured } {
  const captured: Captured = { status: 0, body: undefined };
  const res = {
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
    set() {},
  };
  return { res, captured };
}

function makeReq(opts: {
  version: 1 | 2;
  path: string;
  query: Record<string, unknown>;
  signedQuery?: Record<string, unknown>;
}) {
  const body = {};
  const headers: Record<string, string> = {
    authorization: `Bearer ${TOKEN}`,
    ...popHeaders({ version: opts.version, method: "GET", path: opts.path, query: opts.query, signedQuery: opts.signedQuery, body }),
  };
  const qs = Object.entries(opts.query)
    .map(([k, v]) => `${k}=${String(v)}`)
    .join("&");
  return {
    method: "GET",
    path: opts.path,
    url: qs ? `${opts.path}?${qs}` : opts.path,
    body,
    headers,
    query: opts.query,
    socket: { remoteAddress: "127.0.0.1" },
    get: (name: string) => headers[name.toLowerCase()],
  };
}

async function call(opts: {
  version: 1 | 2;
  path: string;
  query: Record<string, unknown>;
  signedQuery?: Record<string, unknown>;
}): Promise<Captured> {
  const { dispatchHermesGatewayRequest } = await import("../callables/hermesGateway.js");
  // Single typed seam: the dispatcher takes real express req/res; the fakes
  // cover exactly the surface it touches.
  const dispatch: (req: unknown, res: unknown) => Promise<void> = dispatchHermesGatewayRequest as never;
  const { res, captured } = makeRes();
  await dispatch(makeReq(opts), res);
  return captured;
}

function errOf(body: unknown): unknown {
  return isRecord(body) ? body.error : undefined;
}

describe("L2 — gateway PoP v2 query binding", () => {
  beforeEach(() => {
    stored.clear();
    nonceCounter = 0;
  });
  afterEach(() => vi.clearAllMocks());

  it("accepts a v2 signature that binds the canonical query string", async () => {
    seedGrant();
    const res = await call({ version: 2, path: "/events", query: { cursor: "abc", limit: "50" } });
    // PoP passed (not a 401 PoP rejection); the events handler then runs.
    expect(res.status).not.toBe(401);
    expect(res.status).toBe(200);
  });

  it("rejects a v2 request whose query was tampered after signing", async () => {
    seedGrant();
    // Sign over cursor=abc but send cursor=EVIL: the server's canonical query no
    // longer matches the signature.
    const res = await call({
      version: 2,
      path: "/events",
      query: { cursor: "EVIL", limit: "50" },
      signedQuery: { cursor: "abc", limit: "50" },
    });
    expect(res.status).toBe(401);
    expect(errOf(res.body)).toBe("bad_pop_signature");
  });

  it("still accepts a legacy v1 signature during the transition window", async () => {
    seedGrant();
    const res = await call({ version: 1, path: "/events", query: { cursor: "abc", limit: "50" } });
    expect(res.status).not.toBe(401);
    expect(res.status).toBe(200);
  });

  it("refuses a v1 downgrade once the client registered v2 capability", async () => {
    seedGrant(2);
    const res = await call({ version: 1, path: "/events", query: { cursor: "abc" } });
    expect(res.status).toBe(401);
    expect(errOf(res.body)).toBe("pop_v2_required");
  });

  it("a v2-capable client signing v2 with an unprotected query is still accepted", async () => {
    seedGrant(2);
    const res = await call({ version: 2, path: "/events", query: {} });
    expect(res.status).not.toBe(401);
    expect(res.status).toBe(200);
  });
});
