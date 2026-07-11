import { generateKeyPairSync, randomBytes, sign } from "node:crypto";

import { beforeEach, describe, expect, it, vi } from "vitest";

const { store } = vi.hoisted(() => ({ store: new Map<string, Record<string, unknown>>() }));

type Ref = { path: string };

function snapshot(path: string) {
  const data = store.get(path);
  return {
    exists: data !== undefined,
    data: () => data,
    get: (field: string) => data?.[field],
    ref: { path },
  };
}

function mergeWrite(path: string, data: Record<string, unknown>, merge = false): void {
  store.set(path, merge ? { ...(store.get(path) ?? {}), ...data } : { ...data });
}

vi.mock("../adminRuntime.js", () => ({
  db: {
    doc(path: string) {
      return {
        path,
        get: async () => snapshot(path),
        set: async (data: Record<string, unknown>, options?: { merge?: boolean }) =>
          mergeWrite(path, data, options?.merge),
        delete: async () => store.delete(path),
      };
    },
    runTransaction: async (handler: (transaction: unknown) => Promise<unknown>) =>
      handler({
        get: async (ref: Ref) => snapshot(ref.path),
        create: (ref: Ref, data: Record<string, unknown>) => {
          if (store.has(ref.path)) throw new Error("already exists");
          mergeWrite(ref.path, data);
        },
        set: (ref: Ref, data: Record<string, unknown>, options?: { merge?: boolean }) =>
          mergeWrite(ref.path, data, options?.merge),
        update: (ref: Ref, data: Record<string, unknown>) => mergeWrite(ref.path, data, true),
        delete: (ref: Ref) => store.delete(ref.path),
      }),
  },
  auth: {},
}));

vi.mock("firebase-admin/firestore", () => ({
  FieldValue: { serverTimestamp: () => ({ __serverTimestamp: true }) },
  Timestamp: { fromMillis: (millis: number) => ({ toMillis: () => millis }) },
}));

vi.mock("../config.js", () => ({ getConfig: () => ({ enforceAppCheck: true }) }));
vi.mock("../appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
}));
vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return { ...actual, assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined) };
});
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: vi.fn(), logWarn: vi.fn() };
});

import {
  issueIrohControllerRouteChallenge,
  registerIrohControllerRoute,
  resolveActiveIrohControllerRoutes,
  revokeIrohControllerRoute,
} from "../callables/irohControllerRouteCallables.js";
import { parseEscrowPlatform } from "../callables/computerUseSecurityCodecs.js";
import { requireIrohTransportNodeId } from "../callables/irohControllerRouteSecurity.js";
import {
  publishIrohPairingPublicKey,
  publishIrohPairingRecord,
  revokeIrohPairingRecord,
} from "../callables/phoneControlCallables.js";

const UID = "route-owner";
const CONNECTION_ID = "linux-browser-cu";
const HOST_DEVICE_ID = "linux-host-fixture";
const SOURCE_DEVICE_ID = "phone-controller";
const BOB_UID = "route-attacker";
const BASE32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

function rawEd25519PublicKey(publicKey: ReturnType<typeof generateKeyPairSync>["publicKey"]): Buffer {
  return publicKey.export({ format: "der", type: "spki" }).subarray(-32);
}

function base32NoPad(raw: Buffer): string {
  let accumulator = 0;
  let bitCount = 0;
  let encoded = "";
  for (const byte of raw) {
    accumulator = (accumulator << 8) | byte;
    bitCount += 8;
    while (bitCount >= 5) {
      bitCount -= 5;
      encoded += BASE32_ALPHABET[(accumulator >> bitCount) & 31];
      accumulator &= (1 << bitCount) - 1;
    }
  }
  if (bitCount > 0) encoded += BASE32_ALPHABET[(accumulator << (5 - bitCount)) & 31];
  return encoded;
}

function callableRequest(uid: string, data: Record<string, unknown>) {
  return {
    auth: { uid, token: {} },
    app: { appId: "1:123:ios:route-test" },
    data,
    rawRequest: { headers: {} },
  };
}

function callableRunner(callable: unknown): (request: unknown) => Promise<unknown> {
  const run =
    callable && (typeof callable === "object" || typeof callable === "function")
      ? Reflect.get(callable, "run")
      : undefined;
  if (typeof run !== "function") throw new Error("callable test target is missing run()");
  return (request: unknown) => run.call(callable, request);
}

function invoke<T>(callable: unknown, uid: string, data: Record<string, unknown>): Promise<T> {
  return callableRunner(callable)(callableRequest(uid, data)) as Promise<T>;
}

function snapshotTenantPaths(uid: string): Map<string, Record<string, unknown>> {
  return new Map([...store].filter(([path]) => path.startsWith(`users/${uid}/`)));
}

function seedTrustGraph() {
  const host = generateKeyPairSync("ed25519");
  const hostPublic = rawEd25519PublicKey(host.publicKey);
  const hostNodeId = randomBytes(32).toString("hex");
  const publishedAtMillis = Date.now();
  const canonicalPairing = Buffer.from(
    `openburnbar.iroh.pairing.v1|${UID}|${CONNECTION_ID}|${hostNodeId}|||${publishedAtMillis}`,
    "utf8",
  );
  const authority = generateKeyPairSync("ed25519");
  const authorityPublic = rawEd25519PublicKey(authority.publicKey);
  const authorityPeerNodeId = `ios-phone-${authorityPublic.subarray(0, 12).toString("hex")}`;
  const transport = generateKeyPairSync("ed25519");
  const transportNodeId = rawEd25519PublicKey(transport.publicKey).toString("hex");

  store.set(`users/${UID}/escrow_devices/${HOST_DEVICE_ID}`, {
    deviceId: HOST_DEVICE_ID,
    platform: "Linux",
    trustState: "trusted",
  });
  store.set(`users/${UID}/escrow_devices/${SOURCE_DEVICE_ID}`, {
    deviceId: SOURCE_DEVICE_ID,
    platform: "iOS",
    trustState: "trusted",
    peerNodeId: authorityPeerNodeId,
  });
  store.set(`users/${UID}/iroh_pairing_keys/host`, {
    id: "host",
    publicKeyBase64: hostPublic.toString("base64"),
    publishedByDeviceId: HOST_DEVICE_ID,
  });
  store.set(`users/${UID}/iroh_pairing/${CONNECTION_ID}`, {
    id: CONNECTION_ID,
    nodeId: hostNodeId,
    directAddresses: [],
    publishedAtMillis,
    protocolVersion: 1,
    signature: sign(null, canonicalPairing, host.privateKey).toString("base64"),
    publishedByDeviceId: HOST_DEVICE_ID,
    authorizedControllerDeviceIds: [SOURCE_DEVICE_ID],
  });
  store.set(`users/${UID}/iroh_pairing/${CONNECTION_ID}/controllers/${authorityPeerNodeId}`, {
    id: authorityPeerNodeId,
    connectionId: CONNECTION_ID,
    peerNodeId: authorityPeerNodeId,
    deviceId: SOURCE_DEVICE_ID,
    publicKeyBase64: authorityPublic.toString("base64"),
    signingKeyKind: "ed25519",
  });
  return { authority, authorityPeerNodeId, transport, transportNodeId };
}

async function issueChallenge(authorityPeerNodeId: string, transportNodeId: string) {
  return invoke<{
    challengeId: string;
    canonicalPayloadBase64: string;
    registrationGeneration: number;
  }>(issueIrohControllerRouteChallenge, UID, {
    sourceDeviceId: SOURCE_DEVICE_ID,
    connectionId: CONNECTION_ID,
    authorityPeerNodeId,
    transportNodeId,
    nonce: "high-risk-nonce",
  });
}

async function registerChallenge(
  challenge: { challengeId: string; canonicalPayloadBase64: string },
  transportPrivateKey: ReturnType<typeof generateKeyPairSync>["privateKey"],
  authorityPrivateKey: ReturnType<typeof generateKeyPairSync>["privateKey"],
) {
  const payload = Buffer.from(challenge.canonicalPayloadBase64, "base64");
  return invoke<Record<string, unknown>>(registerIrohControllerRoute, UID, {
    challengeId: challenge.challengeId,
    transportSignatureBase64: sign(null, payload, transportPrivateKey).toString("base64"),
    authoritySignatureBase64: sign(null, payload, authorityPrivateKey).toString("base64"),
  });
}

describe("verified iroh controller route registry", () => {
  beforeEach(() => store.clear());

  it("admits attested Linux escrow hosts to publish the signed iroh pairing root", async () => {
    const host = generateKeyPairSync("ed25519");
    const hostNodeId = randomBytes(32).toString("hex");
    store.set(`users/${UID}/escrow_devices/${HOST_DEVICE_ID}`, {
      deviceId: HOST_DEVICE_ID,
      platform: parseEscrowPlatform("Linux"),
      trustState: "trusted",
    });
    await expect(
      invoke(publishIrohPairingPublicKey, UID, {
        deviceId: HOST_DEVICE_ID,
        roleId: "host",
        publicKeyBase64: rawEd25519PublicKey(host.publicKey).toString("base64"),
        nonce: "linux-host-key-nonce",
      }),
    ).resolves.toEqual({ ok: true, roleId: "host" });
    await expect(
      invoke(publishIrohPairingRecord, UID, {
        deviceId: HOST_DEVICE_ID,
        connectionId: CONNECTION_ID,
        nodeId: hostNodeId,
        directAddresses: [],
        publishedAtMillis: Date.now(),
        protocolVersion: 1,
        signature: randomBytes(64).toString("base64"),
        nonce: "linux-host-pairing-nonce",
      }),
    ).resolves.toEqual({ ok: true, connectionId: CONNECTION_ID });
    expect(store.get(`users/${UID}/iroh_pairing/${CONNECTION_ID}`)?.publishedByDeviceId).toBe(HOST_DEVICE_ID);
  });

  it("normalizes legacy base32 NodeIds to current lowercase-hex iroh identity", () => {
    const publicKey = randomBytes(32);
    const legacyNodeId = base32NoPad(publicKey);
    expect(requireIrohTransportNodeId(legacyNodeId)).toMatchObject({
      nodeId: publicKey.toString("hex"),
      wireNodeId: legacyNodeId,
      publicKey,
    });
  });

  it("registers and resolves distinct transport, authority, and device identities", async () => {
    const fixture = seedTrustGraph();
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    const registration = await registerChallenge(
      challenge,
      fixture.transport.privateKey,
      fixture.authority.privateKey,
    );
    expect(registration).toMatchObject({
      ok: true,
      sourceDeviceId: SOURCE_DEVICE_ID,
      transportNodeId: fixture.transportNodeId,
      authorityPeerNodeId: fixture.authorityPeerNodeId,
      generation: 1,
    });

    const resolution = await invoke<{ uid: string; routes: Array<Record<string, unknown>> }>(
      resolveActiveIrohControllerRoutes,
      UID,
      { connectionId: CONNECTION_ID },
    );
    expect(resolution.uid).toBe(UID);
    expect(resolution.routes).toEqual([
      expect.objectContaining({
        connectionId: CONNECTION_ID,
        sourceDeviceId: SOURCE_DEVICE_ID,
        transportNodeId: fixture.transportNodeId,
        authorityPeerNodeId: fixture.authorityPeerNodeId,
        generation: 1,
      }),
    ]);
    expect(JSON.stringify(resolution)).not.toContain("publicKeyBase64");
    expect(JSON.stringify(resolution)).not.toContain("signature");
  });

  it("rejects a forged transport proof without consuming the challenge", async () => {
    const fixture = seedTrustGraph();
    const attacker = generateKeyPairSync("ed25519");
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await expect(registerChallenge(challenge, attacker.privateKey, fixture.authority.privateKey)).rejects.toMatchObject({
      code: "permission-denied",
    });
    expect(store.get(`users/${UID}/iroh_controller_route_challenges/${challenge.challengeId}`)?.status).toBe("pending");
    await expect(
      registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey),
    ).resolves.toMatchObject({ ok: true });
  });

  it("rejects a forged authority proof without consuming the challenge", async () => {
    const fixture = seedTrustGraph();
    const attacker = generateKeyPairSync("ed25519");
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await expect(
      registerChallenge(challenge, fixture.transport.privateKey, attacker.privateKey),
    ).rejects.toMatchObject({ code: "permission-denied" });
    expect(store.get(`users/${UID}/iroh_controller_route_challenges/${challenge.challengeId}`)?.status).toBe("pending");
    await expect(
      registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey),
    ).resolves.toMatchObject({ ok: true });
  });

  it("consumes a successful proof exactly once", async () => {
    const fixture = seedTrustGraph();
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey);
    await expect(
      registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey),
    ).rejects.toMatchObject({
      code: "failed-precondition",
    });
  });

  it("rejects the losing side of concurrent route rotation", async () => {
    const fixture = seedTrustGraph();
    const first = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    const second = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await registerChallenge(first, fixture.transport.privateKey, fixture.authority.privateKey);
    await expect(
      registerChallenge(second, fixture.transport.privateKey, fixture.authority.privateKey),
    ).rejects.toMatchObject({ code: "aborted" });
  });

  it("fails closed for stale pairing, ambiguous controllers, authority rotation, and route expiry", async () => {
    const fixture = seedTrustGraph();
    const pairingPath = `users/${UID}/iroh_pairing/${CONNECTION_ID}`;
    store.set(pairingPath, { ...store.get(pairingPath), publishedAtMillis: Date.now() - 4 * 60 * 1000 });
    await expect(issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId)).rejects.toMatchObject({
      code: "failed-precondition",
    });

    store.clear();
    const fresh = seedTrustGraph();
    store.set(pairingPath, {
      ...store.get(pairingPath),
      authorizedControllerDeviceIds: [SOURCE_DEVICE_ID, "other-phone"],
    });
    await expect(issueChallenge(fresh.authorityPeerNodeId, fresh.transportNodeId)).rejects.toMatchObject({
      code: "permission-denied",
    });

    store.clear();
    const registered = seedTrustGraph();
    const challenge = await issueChallenge(registered.authorityPeerNodeId, registered.transportNodeId);
    await registerChallenge(challenge, registered.transport.privateKey, registered.authority.privateKey);
    const sourceDevicePath = `users/${UID}/escrow_devices/${SOURCE_DEVICE_ID}`;
    store.set(sourceDevicePath, { ...store.get(sourceDevicePath), peerNodeId: "ios-phone-rotated" });
    await expect(invoke(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID })).rejects.toMatchObject(
      { code: "permission-denied" },
    );
    store.set(sourceDevicePath, {
      ...store.get(sourceDevicePath),
      peerNodeId: registered.authorityPeerNodeId,
    });
    const controllerPath = `users/${UID}/iroh_pairing/${CONNECTION_ID}/controllers/${registered.authorityPeerNodeId}`;
    store.set(controllerPath, { ...store.get(controllerPath), publicKeyBase64: randomBytes(32).toString("base64") });
    await expect(invoke(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID })).rejects.toBeTruthy();

    store.clear();
    const expired = seedTrustGraph();
    const expiryChallenge = await issueChallenge(expired.authorityPeerNodeId, expired.transportNodeId);
    await registerChallenge(expiryChallenge, expired.transport.privateKey, expired.authority.privateKey);
    const routePath = `users/${UID}/iroh_pairing/${CONNECTION_ID}/controller_routes/${SOURCE_DEVICE_ID}`;
    store.set(routePath, { ...store.get(routePath), expiresAtMillis: Date.now() - 1 });
    await expect(invoke(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID })).rejects.toMatchObject(
      { code: "failed-precondition" },
    );
  });

  it("revokes durably by advancing the generation and blocks resolution", async () => {
    const fixture = seedTrustGraph();
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey);
    await expect(
      invoke(revokeIrohControllerRoute, UID, {
        sourceDeviceId: SOURCE_DEVICE_ID,
        connectionId: CONNECTION_ID,
        nonce: "revoke-nonce",
      }),
    ).resolves.toMatchObject({ ok: true, generation: 2 });
    await expect(invoke(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID })).rejects.toMatchObject(
      { code: "failed-precondition" },
    );
  });

  it("tombstones an absent route so an outstanding first-generation challenge cannot register", async () => {
    const fixture = seedTrustGraph();
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await expect(
      invoke(revokeIrohControllerRoute, UID, {
        sourceDeviceId: SOURCE_DEVICE_ID,
        connectionId: CONNECTION_ID,
        nonce: "revoke-before-register-nonce",
      }),
    ).resolves.toMatchObject({ ok: true, generation: 1 });
    expect(store.get(`users/${UID}/iroh_pairing/${CONNECTION_ID}/controller_routes/${SOURCE_DEVICE_ID}`)).toMatchObject({
      connectionId: CONNECTION_ID,
      sourceDeviceId: SOURCE_DEVICE_ID,
      status: "revoked",
      generation: 1,
    });
    await expect(
      registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey),
    ).rejects.toMatchObject({ code: "aborted" });
  });

  it("tombstones the verified route when the host revokes its pairing", async () => {
    const fixture = seedTrustGraph();
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey);
    await expect(
      invoke(revokeIrohPairingRecord, UID, {
        deviceId: HOST_DEVICE_ID,
        connectionId: CONNECTION_ID,
        nonce: "host-pairing-revoke-nonce",
      }),
    ).resolves.toEqual({ ok: true, connectionId: CONNECTION_ID });
    expect(store.get(`users/${UID}/iroh_pairing/${CONNECTION_ID}/controller_routes/${SOURCE_DEVICE_ID}`)).toMatchObject(
      { status: "revoked", generation: 2 },
    );
    await expect(invoke(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID })).rejects.toMatchObject(
      { code: "failed-precondition" },
    );
  });

  it("issue challenge scopes every lookup to request.auth.uid", async () => {
    const fixture = seedTrustGraph();
    const before = snapshotTenantPaths(UID);
    await expect(
      invoke(issueIrohControllerRouteChallenge, BOB_UID, {
        sourceDeviceId: SOURCE_DEVICE_ID,
        connectionId: CONNECTION_ID,
        authorityPeerNodeId: fixture.authorityPeerNodeId,
        transportNodeId: fixture.transportNodeId,
        nonce: "attacker-nonce",
      }),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(snapshotTenantPaths(UID)).toEqual(before);
  });

  it("registration cannot consume a cross-user challenge", async () => {
    const fixture = seedTrustGraph();
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    const before = snapshotTenantPaths(UID);
    await expect(
      invoke(registerIrohControllerRoute, BOB_UID, {
        challengeId: challenge.challengeId,
        transportSignatureBase64: sign(
          null,
          Buffer.from(challenge.canonicalPayloadBase64, "base64"),
          fixture.transport.privateKey,
        ).toString("base64"),
        authoritySignatureBase64: sign(
          null,
          Buffer.from(challenge.canonicalPayloadBase64, "base64"),
          fixture.authority.privateKey,
        ).toString("base64"),
      }),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(snapshotTenantPaths(UID)).toEqual(before);
  });

  it("resolution cannot read a cross-user route", async () => {
    seedTrustGraph();
    const before = snapshotTenantPaths(UID);
    await expect(
      invoke(resolveActiveIrohControllerRoutes, BOB_UID, { connectionId: CONNECTION_ID }),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(snapshotTenantPaths(UID)).toEqual(before);
  });

  it("revocation cannot mutate a cross-user route", async () => {
    seedTrustGraph();
    const before = snapshotTenantPaths(UID);
    await expect(
      invoke(revokeIrohControllerRoute, BOB_UID, {
        sourceDeviceId: SOURCE_DEVICE_ID,
        connectionId: CONNECTION_ID,
        nonce: "attacker-revoke-nonce",
      }),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(snapshotTenantPaths(UID)).toEqual(before);
  });
});
