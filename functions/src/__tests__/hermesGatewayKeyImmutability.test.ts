/**
 * Hermes Gateway E2EE — relay-key IMMUTABILITY at the HTTP /runtime surface
 * (Codex finding: KEY IMMUTABILITY). The relay public key is pinned at pairing
 * (trust-on-first-use). After that it is IMMUTABLE: a /runtime request carrying a
 * bearer token must NOT be able to overwrite the pinned agentRelayPublicKey —
 * otherwise the server (or any token holder) could substitute its own key and
 * MITM the sealed channel. Replacing the pinned key requires explicit re-pairing;
 * the server remains PIN-ONLY.
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
  Timestamp: class FakeTimestamp {
    private readonly ms: number;
    constructor(ms: number) {
      this.ms = ms;
    }
    static now(): FakeTimestamp {
      return new FakeTimestamp(Date.now());
    }
    static fromMillis(ms: number): FakeTimestamp {
      return new FakeTimestamp(ms);
    }
    toMillis(): number {
      return this.ms;
    }
  },
}));
vi.mock("firebase-admin/storage", () => ({ getStorage: () => ({ bucket: () => ({ file: () => ({}) }) }) }));

const stored = new Map<string, Record<string, unknown>>();

function snapFor(path: string) {
  return {
    id: path.split("/").pop(),
    ref: docRef(path),
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
  runTransaction: async (fn: (tx: unknown) => Promise<unknown>) => {
    const tx = {
      get: async (ref: { __path: string }) => snapFor(ref.__path),
      set: (ref: { __path: string }, data: Record<string, unknown>, opts?: { merge?: boolean }) => {
        if (opts?.merge === false) stored.set(ref.__path, { ...data });
        else stored.set(ref.__path, { ...stored.get(ref.__path), ...data });
      },
    };
    return fn(tx);
  },
  collection: (path: string) => {
    const filters: Array<{ field: string; value: unknown }> = [];
    let limitCount = Number.POSITIVE_INFINITY;
    const query = {
      doc: (id: string) => docRef(`${path}/${id}`),
      where(field: string, op: string, value: unknown) {
        if (op !== "==") throw new Error(`Unsupported fake Firestore operator ${op}`);
        filters.push({ field, value });
        return query;
      },
      limit(count: number) {
        limitCount = count;
        return query;
      },
      get: async () => {
        const prefix = `${path}/`;
        const docs = [...stored.entries()]
          .filter(([docPath, data]) => {
            if (!docPath.startsWith(prefix)) return false;
            if (docPath.slice(prefix.length).includes("/")) return false;
            return filters.every(({ field, value }) => data[field] === value);
          })
          .slice(0, limitCount)
          .map(([docPath]) => snapFor(docPath));
        return { docs, empty: docs.length === 0, size: docs.length };
      },
    };
    return query;
  },
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

function postRequest(path: string, body: Record<string, unknown>, headers: Record<string, string> = {}) {
  return {
    method: "POST",
    path,
    url: path,
    body,
    query: {},
    headers,
    get(name: string) {
      return headers[name.toLowerCase()];
    },
  };
}

function runtimeRequest(body: Record<string, unknown>) {
  return postRequest("/runtime", body, { authorization: `Bearer ${TOKEN}` });
}

function devicePollRequest(body: Record<string, unknown>) {
  return postRequest("/device/poll", body);
}

function deviceStartRequest(body: Record<string, unknown>) {
  return postRequest("/device/start", body, { "x-forwarded-for": "127.0.0.1" });
}

function record(value: unknown, label = "value"): Record<string, unknown> {
  expect(value, `${label} must be an object`).toEqual(expect.any(Object));
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return Object.fromEntries(Object.entries(value));
}

async function runHttpHandler(handler: unknown, req: ReturnType<typeof postRequest>, res: FakeRes): Promise<void> {
  const run = Reflect.get(Object(handler), "run");
  const callable = typeof run === "function" ? run : handler;
  if (typeof callable !== "function") {
    throw new Error("Expected HTTP handler to be callable");
  }
  await callable(req, res);
}

function callableRequest(data: Record<string, unknown>) {
  return { auth: { uid: UID, token: {} }, app: { appId: "test-app" }, rawRequest: { headers: {} }, data };
}

function callableRun(callable: unknown): (request: unknown) => Promise<unknown> {
  const run = Reflect.get(Object(callable), "run");
  if (typeof run !== "function") {
    throw new Error("Expected callable to expose run()");
  }
  return run;
}

async function withSignalWritesEnabled<T>(fn: () => Promise<T>): Promise<T> {
  const gateway = await import("../hermesGateway.js");
  const previous = [...gateway.HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS];
  gateway.HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.clear();
  gateway.HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.add(gateway.HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL);
  try {
    return await fn();
  } finally {
    gateway.HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.clear();
    for (const version of previous) gateway.HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS.add(version);
  }
}

function signalCapabilities(platform: string, appBuild: string): Record<string, unknown> {
  return {
    supportsRelayEnvelopeVersions: [2, 3],
    preferredRelayEnvelopeVersion: 3,
    supportsHpkeV3: true,
    supportsSignalEnvelope: true,
    clientPlatform: platform,
    clientAppBuild: appBuild,
  };
}

function storedClient(): Record<string, unknown> {
  const client = stored.get(`users/${UID}/hermes_gateway_clients/${CLIENT_ID}`);
  if (!client) {
    throw new Error("Expected seeded Hermes gateway client to be stored");
  }
  return client;
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
    await runHttpHandler(
      burnBarHermesGateway,
      runtimeRequest({ agentRelayPublicKey: ATTACKER_AGENT_KEY, currentModelId: "minimax-m2.7" }),
      res,
    );
    expect(res._status).toBe(200);

    const client = storedClient();
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
    await runHttpHandler(burnBarHermesGateway, runtimeRequest({ agentRelayPublicKey: PINNED_AGENT_KEY }), res);
    expect(res._status).toBe(200);

    const client = storedClient();
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
    await runHttpHandler(burnBarHermesGateway, runtimeRequest({ agentRelayPublicKey: PINNED_AGENT_KEY }), res);
    expect(res._status).toBe(200);
    const client = storedClient();
    expect(client.agentRelayPublicKey).toBe(PINNED_AGENT_KEY);
  });

  it("activation candidate: /runtime persists negotiated Signal support only when both endpoints advertise it", async () => {
    await withSignalWritesEnabled(async () => {
      const { burnBarHermesGateway } = await import("../callables/hermesGateway.js");
      const { hashHermesGatewayBearerToken } = await import("../hermesGateway.js");
      const tokenHash = hashHermesGatewayBearerToken(TOKEN);
      await seedPairedClient(tokenHash, PINNED_AGENT_KEY);
      stored.set(`users/${UID}/hermes_gateway_clients/${CLIENT_ID}`, {
        ...storedClient(),
        phoneSupportsRelayEnvelopeVersions: [2, 3],
        phonePreferredRelayEnvelopeVersion: 3,
        phoneSupportsHpkeV3: true,
        phoneSupportsSignalEnvelope: true,
      });

      const res = fakeRes();
      await runHttpHandler(
        burnBarHermesGateway,
        runtimeRequest({
          agentRelayPublicKey: PINNED_AGENT_KEY,
          ...signalCapabilities("python", "hermes-agent-signal"),
        }),
        res,
      );

      expect(res._status).toBe(200);
      let client = storedClient();
      expect(client.agentSupportsSignalEnvelope).toBe(true);
      expect(client.phoneSupportsSignalEnvelope).toBe(true);
      expect(client.supportsSignalEnvelope).toBe(true);
      expect(client.supportsRelayEnvelopeVersions).toEqual([2, 3]);
      expect(client.preferredRelayEnvelopeVersion).toBe(3);

      stored.set(`users/${UID}/hermes_gateway_clients/${CLIENT_ID}`, {
        ...client,
        phoneSupportsSignalEnvelope: false,
      });
      const legacyPhoneRes = fakeRes();
      await runHttpHandler(
        burnBarHermesGateway,
        runtimeRequest({
          agentRelayPublicKey: PINNED_AGENT_KEY,
          ...signalCapabilities("python", "hermes-agent-signal"),
        }),
        legacyPhoneRes,
      );

      expect(legacyPhoneRes._status).toBe(200);
      client = storedClient();
      expect(client.agentSupportsSignalEnvelope).toBe(true);
      expect(client.phoneSupportsSignalEnvelope).toBe(false);
      expect(client.supportsSignalEnvelope).toBe(false);
    });
  });

  it("activation candidate: /device/start stores agent Signal capability on the pending session", async () => {
    await withSignalWritesEnabled(async () => {
      const { dispatchHermesGatewayRequest } = await import("../callables/hermesGateway.js");

      const res = fakeRes();
      await dispatchHermesGatewayRequest(
        deviceStartRequest({
          clientName: "Hermes Agent Signal",
          agentRelayPublicKey: PINNED_AGENT_KEY,
          ...signalCapabilities("python", "hermes-agent-signal"),
        }),
        res,
      );

      expect(res._status).toBe(200);
      const body = record(res._body, "device start response body");
      const deviceCode = body.deviceCode;
      expect(typeof deviceCode).toBe("string");
      const session = stored.get(`hermes_gateway_device_sessions/${deviceCode}`);
      expect(session?.agentRelayPublicKey).toBe(PINNED_AGENT_KEY);
      expect(session?.agentSupportsRelayEnvelopeVersions).toEqual([2, 3]);
      expect(session?.agentPreferredRelayEnvelopeVersion).toBe(3);
      expect(session?.agentSupportsHpkeV3).toBe(true);
      expect(session?.agentSupportsSignalEnvelope).toBe(true);
      expect(session?.agentPlatform).toBe("python");
      expect(session?.agentAppBuild).toBe("hermes-agent-signal");
    });
  });

  it("returns pairing-rooted uid/clientId and phone E2EE material from approved device polls", async () => {
    const { dispatchHermesGatewayRequest } = await import("../callables/hermesGateway.js");
    const { Timestamp } = await import("firebase-admin/firestore");
    const { hashHermesGatewayBearerToken, hashHermesGatewayDeviceSecret } = await import("../hermesGateway.js");
    const accessToken = `obb_hgw_${"B".repeat(20)}`;
    const tokenHash = hashHermesGatewayBearerToken(accessToken);
    const deviceCode = "hgd_poll_identity";
    const deviceSecret = "poll-secret";
    const phoneRatchetIdentityPublicKey = Buffer.alloc(32, 13).toString("base64");
    const phoneRatchetSigningPublicKey = Buffer.alloc(65, 14).toString("base64");
    const phoneRatchetSignedPreKeyPublicKey = Buffer.alloc(65, 15).toString("base64");
    const phoneRatchetSignedPreKeySignature = Buffer.alloc(64, 16).toString("base64");

    await seedPairedClient(tokenHash, PINNED_AGENT_KEY);
    stored.set(`users/${UID}/hermes_gateway_clients/${CLIENT_ID}`, {
      ...storedClient(),
      phoneRelayPublicKey: PHONE_KEY,
      phoneRelayKeyVersion: 1,
      phoneRelayEncryption: "p256-hkdf-sha256-aesgcm",
      phoneSupportsRelayEnvelopeVersions: [2, 3],
      phonePreferredRelayEnvelopeVersion: 3,
      phoneSupportsHpkeV3: true,
      phoneRatchetIdentityPublicKey,
      phoneRatchetSigningPublicKey,
      phoneRatchetSignedPreKeyPublicKey,
      phoneRatchetSignedPreKeyId: "phone-spk-1",
      phoneRatchetSignedPreKeySignature,
      phoneSupportsRatchetV1: true,
      supportsRatchetV1: true,
    });
    stored.set(`hermes_gateway_device_sessions/${deviceCode}`, {
      deviceCode,
      deviceSecretHash: hashHermesGatewayDeviceSecret(deviceSecret),
      status: "approved",
      uid: UID,
      clientId: CLIENT_ID,
      accessToken,
      scopes: ["hermes.gateway.read", "hermes.gateway.write"],
      homeDestinationId: "burnbar:home",
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
    });

    const res = fakeRes();
    await dispatchHermesGatewayRequest(devicePollRequest({ deviceCode, deviceSecret }), res);

    expect(res._status).toBe(200);
    const body = record(res._body, "device poll response body");
    expect(body.status).toBe("approved");
    expect(body.uid).toBe(UID);
    expect(body.userId).toBe(UID);
    expect(body.clientId).toBe(CLIENT_ID);
    expect(body.phoneRelayPublicKey).toBe(PHONE_KEY);
    expect(body.phoneSupportsRelayEnvelopeVersions).toEqual([2, 3]);
    expect(body.phoneRatchetIdentityPublicKey).toBe(phoneRatchetIdentityPublicKey);
    expect(body.phoneRatchetSignedPreKeyId).toBe("phone-spk-1");
    expect(body.supportsRatchetV1).toBe(true);
    const client = record(body.client, "device poll client");
    expect(client.id).toBe(CLIENT_ID);
    expect(client.uid).toBeUndefined();
    expect(stored.has(`hermes_gateway_device_sessions/${deviceCode}`)).toBe(false);
  });

  it("activation candidate: approval persists Signal capabilities and /device/poll returns them", async () => {
    await withSignalWritesEnabled(async () => {
      const { approveHermesGatewayDeviceGrant, dispatchHermesGatewayRequest } =
        await import("../callables/hermesGateway.js");
      const { Timestamp } = await import("firebase-admin/firestore");
      const { hashHermesGatewayDeviceSecret } = await import("../hermesGateway.js");
      const deviceCode = "hgd_signal_approval";
      const deviceSecret = "signal-approval-secret";
      const userCode = "SIG1-2345";

      stored.set(`hermes_gateway_device_sessions/${deviceCode}`, {
        deviceCode,
        userCode,
        deviceSecretHash: hashHermesGatewayDeviceSecret(deviceSecret),
        status: "pending",
        clientName: "Hermes Agent Signal",
        requestedScopes: ["hermes.gateway.read", "hermes.gateway.write"],
        agentRelayPublicKey: PINNED_AGENT_KEY,
        agentRelayKeyVersion: 1,
        agentRelayEncryption: "p256-hkdf-sha256-aesgcm",
        agentSupportsRelayEnvelopeVersions: [2, 3],
        agentPreferredRelayEnvelopeVersion: 3,
        agentSupportsHpkeV3: true,
        agentSupportsSignalEnvelope: true,
        agentPlatform: "python",
        agentAppBuild: "hermes-agent-signal",
        expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      });

      const runApprove = callableRun(approveHermesGatewayDeviceGrant);
      const approveResult = record(
        await runApprove(
          callableRequest({
            userCode,
            displayName: "Hermes Agent Signal",
            destinationId: "burnbar:home",
            phoneRelayPublicKey: PHONE_KEY,
            phoneRelayKeyVersion: 1,
            phoneRelayEncryption: "p256-hkdf-sha256-aesgcm",
            ...signalCapabilities("ios", "openburnbar-signal"),
          }),
        ),
        "approval result",
      );
      const approvedClient = record(approveResult.client, "approved client");
      const clientId = String(approvedClient.id);
      expect(approvedClient.agentSupportsSignalEnvelope).toBe(true);
      expect(approvedClient.phoneSupportsSignalEnvelope).toBe(true);
      expect(approvedClient.supportsSignalEnvelope).toBe(true);
      expect(approvedClient.supportsRelayEnvelopeVersions).toEqual([2, 3]);
      expect(approvedClient.preferredRelayEnvelopeVersion).toBe(3);

      const persistedClient = stored.get(`users/${UID}/hermes_gateway_clients/${clientId}`);
      expect(persistedClient?.agentSupportsSignalEnvelope).toBe(true);
      expect(persistedClient?.phoneSupportsSignalEnvelope).toBe(true);
      expect(persistedClient?.supportsSignalEnvelope).toBe(true);

      const pollRes = fakeRes();
      await dispatchHermesGatewayRequest(devicePollRequest({ deviceCode, deviceSecret }), pollRes);
      expect(pollRes._status).toBe(200);
      const pollBody = record(pollRes._body, "device poll response body");
      expect(pollBody.status).toBe("approved");
      expect(pollBody.clientId).toBe(clientId);
      expect(pollBody.phoneSupportsSignalEnvelope).toBe(true);
      const pollClient = record(pollBody.client, "device poll client");
      expect(pollClient.agentSupportsSignalEnvelope).toBe(true);
      expect(pollClient.phoneSupportsSignalEnvelope).toBe(true);
      expect(pollClient.supportsSignalEnvelope).toBe(true);
      expect(stored.has(`hermes_gateway_device_sessions/${deviceCode}`)).toBe(false);
    });
  });
});
