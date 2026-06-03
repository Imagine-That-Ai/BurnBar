/**
 * Hermes Gateway E2EE (schema 2) — enqueueHermesGatewayEvent must FORWARD a
 * sealed relayEnvelope opaquely and persist NO plaintext body. This proves:
 *   1. A sealed event writes only routing fields + relayEnvelope — text,
 *      senderDisplayName and threadId never touch the stored doc.
 *   2. A relay-capable client that supplies a plaintext `text` (no envelope) is
 *      rejected with `ciphertext_required` (fail toward privacy when sealed).
 *   3. A model_switch on a relay-capable client is itself SEALED: the server
 *      requires the relayEnvelope (the "/model …" command body is private),
 *      forwards it opaquely, routes by cleartext modelId, and stores NO generic
 *      text / senderDisplayName / threadId. An unsealed model_switch to a relay-
 *      capable client is rejected (Codex finding: MODEL_SWITCH SEALED).
 *
 * Mirrors the callable-invocation pattern in projectMemoryDocId.test.ts: an
 * in-memory Firestore double + the real validators, with only the Pro/entitlement
 * gate stubbed so the call runs without seeded entitlement docs.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));

// Real validators (requireGatewayRelayEnvelope, sanitizers, boundedTrimmedString,
// …) but the three entitlement predicates the gateway gate consults are forced
// true so the callable runs without seeded entitlement docs.
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

// In-memory Firestore double keyed by full doc path, with just enough of the
// transaction surface enqueueHermesGatewayEvent uses (runTransaction + tx.get/set).
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

type Runnable = { run: (request: unknown) => Promise<unknown> };

const UID = "userA";
const TARGET_CLIENT_ID = "hgw_target";
const SEALED_EVENT_ID = "evt_test_envelope";
const PLAINTEXT_TEXT = "the private message body";
const PLAINTEXT_NAME = "Alberto";
const PLAINTEXT_THREAD = "thread-secret-id";

function sealedEnvelope() {
  return {
    payloadCiphertext: Buffer.from("sealed-event-payload-bytes").toString("base64"),
    wrappedKey: Buffer.from("ephpub65bytes-plus-nonce-ct-tag").toString("base64"),
    relayEncryption: "p256-hkdf-sha256-aesgcm",
    relayKeyVersion: 1,
  };
}

function seedRelayCapableTargetClient(): void {
  stored.set(`users/${UID}/hermes_gateway_clients/${TARGET_CLIENT_ID}`, {
    id: TARGET_CLIENT_ID,
    uid: UID,
    displayName: "Hermes Agent",
    status: "active",
    tokenHash: "a".repeat(64),
    tokenPreview: "obb_hgw_...abcd",
    scopes: ["hermes.gateway.read", "hermes.gateway.write"],
    homeDestinationId: "burnbar:home",
    agentRelayPublicKey: "BA".repeat(44).slice(0, 88),
    agentRelayKeyVersion: 1,
    agentRelayEncryption: "p256-hkdf-sha256-aesgcm",
    phoneRelayPublicKey: "BB".repeat(44).slice(0, 88),
    phoneRelayKeyVersion: 1,
    phoneRelayEncryption: "p256-hkdf-sha256-aesgcm",
    relayCapable: true,
    runtimeModelOptions: [
      { providerId: "hermes", providerName: "Hermes", modelId: "minimax-m2.7", displayName: "MiniMax" },
    ],
    createdAt: "2026-06-01T00:00:00.000Z",
    updatedAt: "2026-06-01T00:00:00.000Z",
    schemaVersion: 2,
  });
}

function request(data: Record<string, unknown>) {
  return { auth: { uid: UID, token: {} }, app: { appId: "test-app" }, rawRequest: { headers: {} }, data };
}

describe("enqueueHermesGatewayEvent — sealed-only wire (schema 2)", () => {
  beforeEach(() => {
    stored.clear();
    seedRelayCapableTargetClient();
  });
  afterEach(() => vi.clearAllMocks());

  it("forwards the relayEnvelope opaquely and persists NO plaintext body", async () => {
    const { enqueueHermesGatewayEvent } = await import("../callables/hermesGateway.js");
    const run = (enqueueHermesGatewayEvent as unknown as Runnable).run;

    const res = (await run(
      request({
        targetClientId: TARGET_CLIENT_ID,
        eventId: SEALED_EVENT_ID,
        relayEnvelope: sealedEnvelope(),
        senderId: "burnbar-user",
      }),
    )) as { id: string };
    expect(res.id).toBe(SEALED_EVENT_ID);

    const eventPath = Object.keys(Object.fromEntries(stored)).find((p) =>
      p.startsWith(`users/${UID}/hermes_gateway_events/`),
    );
    expect(eventPath).toBeDefined();
    const event = stored.get(eventPath!)!;

    // Sealed envelope is stored verbatim; routing fields kept.
    expect(event.relayEnvelope).toEqual(sealedEnvelope());
    expect(event.targetClientId).toBe(TARGET_CLIENT_ID);
    expect(event.senderId).toBe("burnbar-user");
    expect(event.schemaVersion).toBe(2);

    // NO plaintext private fields anywhere on the stored doc.
    expect(event).not.toHaveProperty("text");
    expect(event).not.toHaveProperty("senderDisplayName");
    expect(event).not.toHaveProperty("threadId");
    const leaves: string[] = [];
    const walk = (v: unknown) => {
      if (typeof v === "string") leaves.push(v);
      else if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === "object") Object.values(v).forEach(walk);
    };
    walk(event);
    expect(leaves).not.toContain(PLAINTEXT_TEXT);
    expect(leaves).not.toContain(PLAINTEXT_NAME);
    expect(leaves).not.toContain(PLAINTEXT_THREAD);
  });

  it("rejects a relay-capable client that sends plaintext text with no envelope", async () => {
    const { enqueueHermesGatewayEvent } = await import("../callables/hermesGateway.js");
    const run = (enqueueHermesGatewayEvent as unknown as Runnable).run;
    await expect(
      run(
        request({
          targetClientId: TARGET_CLIENT_ID,
          text: PLAINTEXT_TEXT,
          senderDisplayName: PLAINTEXT_NAME,
          threadId: PLAINTEXT_THREAD,
        }),
      ),
    ).rejects.toThrow(/ciphertext_required/);
    // Nothing leaked into an event doc on the rejected path.
    const leaked = [...stored.keys()].some((p) => p.startsWith(`users/${UID}/hermes_gateway_events/`));
    expect(leaked).toBe(false);
  });

  it("rejects a malformed relayEnvelope (wrong algorithm constant)", async () => {
    const { enqueueHermesGatewayEvent } = await import("../callables/hermesGateway.js");
    const run = (enqueueHermesGatewayEvent as unknown as Runnable).run;
    await expect(
      run(
        request({
          targetClientId: TARGET_CLIENT_ID,
          relayEnvelope: { ...sealedEnvelope(), relayEncryption: "AES-256-GCM" },
        }),
      ),
    ).rejects.toThrow(/relayEncryption/);
  });

  it("requires a sealed relayEnvelope for a model_switch on a relay-capable client", async () => {
    const { enqueueHermesGatewayEvent } = await import("../callables/hermesGateway.js");
    const run = (enqueueHermesGatewayEvent as unknown as Runnable).run;
    // An unsealed model_switch (plaintext command, no envelope) is rejected: the
    // server no longer reads/validates the model command in cleartext.
    await expect(
      run(
        request({
          targetClientId: TARGET_CLIENT_ID,
          eventKind: "model_switch",
          modelId: "minimax-m2.7",
          text: "/model minimax-m2.7",
        }),
      ),
    ).rejects.toThrow(/relay envelope|relayEnvelope/);
    const leaked = [...stored.keys()].some((p) => p.startsWith(`users/${UID}/hermes_gateway_events/`));
    expect(leaked).toBe(false);
  });

  it("does NOT block a sealed model_switch on a model absent from the catalog (agent decides)", async () => {
    const { enqueueHermesGatewayEvent } = await import("../callables/hermesGateway.js");
    const run = (enqueueHermesGatewayEvent as unknown as Runnable).run;
    // The seeded client advertises only "minimax-m2.7". A sealed switch to an
    // unadvertised model must NOT be pre-rejected by the server — the agent
    // validates against its own catalog after opening the sealed command.
    await run(
      request({
        targetClientId: TARGET_CLIENT_ID,
        eventKind: "model_switch",
        modelId: "gpt-5-unlisted",
        eventId: "evt_sealed_switch_unlisted",
        relayEnvelope: sealedEnvelope(),
      }),
    );
    const eventPath = [...stored.keys()].find((p) => p.startsWith(`users/${UID}/hermes_gateway_events/`));
    const event = stored.get(eventPath!)!;
    expect(event.kind).toBe("model_switch");
    expect(event.modelId).toBe("gpt-5-unlisted");
  });

  it("stores a sealed model_switch with the envelope + cleartext modelId, no private body fields", async () => {
    const { enqueueHermesGatewayEvent } = await import("../callables/hermesGateway.js");
    const run = (enqueueHermesGatewayEvent as unknown as Runnable).run;
    await run(
      request({
        targetClientId: TARGET_CLIENT_ID,
        eventKind: "model_switch",
        modelId: "minimax-m2.7",
        eventId: "evt_sealed_switch",
        relayEnvelope: sealedEnvelope(),
        senderDisplayName: PLAINTEXT_NAME,
        threadId: PLAINTEXT_THREAD,
        text: "/model minimax-m2.7",
      }),
    );
    const eventPath = [...stored.keys()].find((p) => p.startsWith(`users/${UID}/hermes_gateway_events/`));
    const event = stored.get(eventPath!)!;
    expect(event.kind).toBe("model_switch");
    expect(event.modelId).toBe("minimax-m2.7");
    // The sealed command body rides in the envelope; routing modelId is cleartext.
    expect(event.relayEnvelope).toEqual(sealedEnvelope());
    // NO plaintext private fields touch the stored doc.
    expect(event).not.toHaveProperty("text");
    expect(event).not.toHaveProperty("senderDisplayName");
    expect(event).not.toHaveProperty("threadId");
    const leaves: string[] = [];
    const walk = (v: unknown) => {
      if (typeof v === "string") leaves.push(v);
      else if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === "object") Object.values(v).forEach(walk);
    };
    walk(event);
    expect(leaves).not.toContain(PLAINTEXT_NAME);
    expect(leaves).not.toContain(PLAINTEXT_THREAD);
    expect(leaves).not.toContain("/model minimax-m2.7");
  });
});
