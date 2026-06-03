/**
 * Hermes Gateway E2EE — relay-key IMMUTABILITY at the HTTP /runtime surface
 * (Codex finding: KEY IMMUTABILITY). The relay public key is pinned at pairing
 * (trust-on-first-use). After that it is IMMUTABLE: a /runtime request carrying a
 * bearer token must NOT be able to overwrite the pinned agentRelayPublicKey —
 * otherwise the server (or any token holder) could substitute its own key and
 * MITM the sealed channel. Signed key rotation is a deferred follow-up; until then
 * the server is PIN-ONLY.
 *
 * This drives the real burnBarHermesGateway onRequest handler against an in-memory
 * Firestore double, with only the Pro/entitlement predicates stubbed true.
 */
import { EventEmitter } from "node:events";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));
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
  Timestamp: {
    now: () => ({ __ts: true, toMillis: () => Date.now() }),
    fromMillis: (ms: number) => ({ __ts: true, toMillis: () => ms }),
  },
}));
vi.mock("firebase-admin/storage", () => ({ getStorage: () => ({ bucket: () => ({ file: () => ({}) }) }) }));

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
    set: async (data: Record<string, unknown>, opts?: { merge?: boolean }) => {
      if (opts?.merge === false) stored.set(path, { ...data });
      else stored.set(path, { ...stored.get(path), ...data });
    },
    delete: async () => void stored.delete(path),
  };
}

const dbMock = {
  doc: (path: string) => docRef(path),
  collection: () => ({ doc: (id: string) => docRef(id), get: async () => ({ docs: [], empty: true }) }),
};

vi.mock("../adminRuntime.js", () => ({ db: dbMock, auth: {} }));

process.env.ENFORCE_APP_CHECK = "false";

// A base64 X9.63 uncompressed P-256 key: 65 bytes, first byte 0x04.
const PINNED_AGENT_KEY = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 7)]).toString("base64");
const ATTACKER_AGENT_KEY = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 9)]).toString("base64");
const PHONE_KEY = Buffer.concat([Buffer.from([0x04]), Buffer.alloc(64, 3)]).toString("base64");

const UID = "userA";
const CLIENT_ID = "hgw_runtime_client";
const TOKEN = `obb_hgw_${"A".repeat(20)}`;

// An Express/Node-response double sufficient for the firebase-functions onRequest
// wrapper: the cors middleware (cors:true) reads/sets headers and the wrapper
// resolves its promise on the "finish" event, which we emit once the handler has
// written its body.
class FakeRes extends EventEmitter {
  _status = 0;
  _body: unknown = undefined;
  private _headers: Record<string, string> = {};
  status(code: number): this {
    this._status = code;
    return this;
  }
  json(body: unknown): void {
    this._body = body;
    this.emit("finish");
  }
  send(body?: unknown): void {
    if (body !== undefined) this._body = body;
    this.emit("finish");
  }
  end(): void {
    this.emit("finish");
  }
  set(name: string, value: string): void {
    this._headers[name.toLowerCase()] = value;
  }
  setHeader(name: string, value: string): void {
    this._headers[name.toLowerCase()] = value;
  }
  getHeader(name: string): string | undefined {
    return this._headers[name.toLowerCase()];
  }
}

function fakeRes(): FakeRes {
  return new FakeRes();
}

function runtimeRequest(body: Record<string, unknown>) {
  return {
    method: "POST",
    path: "/runtime",
    url: "/runtime",
    body,
    query: {},
    headers: { authorization: `Bearer ${TOKEN}` },
    get(name: string) {
      return name.toLowerCase() === "authorization" ? `Bearer ${TOKEN}` : undefined;
    },
  };
}

async function seedPairedClient(tokenHash: string, agentKey: string | undefined): Promise<void> {
  stored.set(`hermes_gateway_token_index/${tokenHash}`, { uid: UID, clientId: CLIENT_ID, status: "active" });
  stored.set(`users/${UID}/hermes_gateway_clients/${CLIENT_ID}`, {
    id: CLIENT_ID,
    uid: UID,
    displayName: "Hermes Agent",
    status: "active",
    tokenHash,
    tokenPreview: "obb_hgw_...abcd",
    scopes: ["hermes.gateway.read", "hermes.gateway.write"],
    homeDestinationId: "burnbar:home",
    ...(agentKey
      ? { agentRelayPublicKey: agentKey, agentRelayKeyVersion: 1, agentRelayEncryption: "p256-hkdf-sha256-aesgcm" }
      : {}),
    phoneRelayPublicKey: PHONE_KEY,
    phoneRelayKeyVersion: 1,
    phoneRelayEncryption: "p256-hkdf-sha256-aesgcm",
    relayCapable: !!agentKey,
    expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
    createdAt: "2026-06-01T00:00:00.000Z",
    updatedAt: "2026-06-01T00:00:00.000Z",
    schemaVersion: 2,
  });
}

describe("burnBarHermesGateway /runtime — relay-key immutability (pin-only TOFU)", () => {
  beforeEach(() => stored.clear());
  afterEach(() => vi.clearAllMocks());

  it("REFUSES to overwrite an already-pinned agentRelayPublicKey (no MITM swap)", async () => {
    const { burnBarHermesGateway } = await import("../callables/hermesGateway.js");
    const { hashHermesGatewayBearerToken } = await import("../hermesGateway.js");
    const tokenHash = hashHermesGatewayBearerToken(TOKEN);
    await seedPairedClient(tokenHash, PINNED_AGENT_KEY);

    const res = fakeRes();
    await (burnBarHermesGateway as unknown as (req: unknown, res: unknown) => Promise<void>)(
      runtimeRequest({ agentRelayPublicKey: ATTACKER_AGENT_KEY, currentModelId: "minimax-m2.7" }),
      res,
    );
    expect(res._status).toBe(200);

    const client = stored.get(`users/${UID}/hermes_gateway_clients/${CLIENT_ID}`)!;
    // The pinned key is UNCHANGED — the attacker's substituted key never lands.
    expect(client.agentRelayPublicKey).toBe(PINNED_AGENT_KEY);
    expect(client.agentRelayPublicKey).not.toBe(ATTACKER_AGENT_KEY);
    // Routine /runtime fields still update.
    expect(client.runtimeModelId).toBe("minimax-m2.7");
  });

  it("ESTABLISHES the agent key on first pairing when none is pinned yet (TOFU)", async () => {
    const { burnBarHermesGateway } = await import("../callables/hermesGateway.js");
    const { hashHermesGatewayBearerToken } = await import("../hermesGateway.js");
    const tokenHash = hashHermesGatewayBearerToken(TOKEN);
    await seedPairedClient(tokenHash, undefined); // no agent key yet

    const res = fakeRes();
    await (burnBarHermesGateway as unknown as (req: unknown, res: unknown) => Promise<void>)(
      runtimeRequest({ agentRelayPublicKey: PINNED_AGENT_KEY }),
      res,
    );
    expect(res._status).toBe(200);

    const client = stored.get(`users/${UID}/hermes_gateway_clients/${CLIENT_ID}`)!;
    // First-pairing pin succeeds, and relayCapable flips true (phone key on record).
    expect(client.agentRelayPublicKey).toBe(PINNED_AGENT_KEY);
    expect(client.relayCapable).toBe(true);
  });

  it("treats a re-publish of the SAME pinned key as a harmless no-op", async () => {
    const { burnBarHermesGateway } = await import("../callables/hermesGateway.js");
    const { hashHermesGatewayBearerToken } = await import("../hermesGateway.js");
    const tokenHash = hashHermesGatewayBearerToken(TOKEN);
    await seedPairedClient(tokenHash, PINNED_AGENT_KEY);

    const res = fakeRes();
    await (burnBarHermesGateway as unknown as (req: unknown, res: unknown) => Promise<void>)(
      runtimeRequest({ agentRelayPublicKey: PINNED_AGENT_KEY }),
      res,
    );
    expect(res._status).toBe(200);
    const client = stored.get(`users/${UID}/hermes_gateway_clients/${CLIENT_ID}`)!;
    expect(client.agentRelayPublicKey).toBe(PINNED_AGENT_KEY);
  });
});
