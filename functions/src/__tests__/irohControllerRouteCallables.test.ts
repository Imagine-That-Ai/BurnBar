import { generateKeyPairSync, randomBytes, sign } from "node:crypto";

import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  base32NoPad,
  callableRequest,
  callableRunner,
  rawEd25519PublicKey,
  requireActiveRouteResolution,
  requireNumber,
  requireRecord,
  requireRouteChallenge,
  seedRouteTrustGraph,
  snapshotTenantPaths,
} from "./irohControllerRouteTestSupport.js";

const { store } = vi.hoisted(() => ({ store: new Map<string, Record<string, unknown>>() }));

type Ref = { path: string };

function invokeCallable(callable: unknown, uid: string, data: Record<string, unknown>): Promise<unknown> {
  return callableRunner(callable)(callableRequest(uid, data));
}

function invokeCallableForApp(
  callable: unknown,
  uid: string,
  appId: string,
  data: Record<string, unknown>,
): Promise<unknown> {
  return callableRunner(callable)(callableRequest(uid, data, appId));
}

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

vi.mock("../config.js", () => ({
  getConfig: () => ({ enforceAppCheck: true, linuxAppCheckAppID: "1:123:linux:route-test" }),
}));
vi.mock("../appCheckAttestation.js", () => ({
  enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
  readAppIdFromCallableRequest: (request: { app?: { appId?: string } }) => request.app?.appId,
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

function seedTrustGraph() {
  return seedRouteTrustGraph({
    connectionId: CONNECTION_ID,
    hostDeviceId: HOST_DEVICE_ID,
    sourceDeviceId: SOURCE_DEVICE_ID,
    store,
    uid: UID,
  });
}

async function issueChallenge(authorityPeerNodeId: string, transportNodeId: string) {
  return requireRouteChallenge(
    await invokeCallable(issueIrohControllerRouteChallenge, UID, {
      sourceDeviceId: SOURCE_DEVICE_ID,
      connectionId: CONNECTION_ID,
      authorityPeerNodeId,
      transportNodeId,
      expectedUid: UID,
      nonce: "high-risk-nonce",
    }),
  );
}

async function registerChallenge(
  challenge: Pick<ReturnType<typeof requireRouteChallenge>, "challengeId" | "canonicalPayloadBase64">,
  transportPrivateKey: ReturnType<typeof generateKeyPairSync>["privateKey"],
  authorityPrivateKey?: ReturnType<typeof generateKeyPairSync>["privateKey"],
) {
  const payload = Buffer.from(challenge.canonicalPayloadBase64, "base64");
  return invokeCallable(registerIrohControllerRoute, UID, {
    challengeId: challenge.challengeId,
    transportSignatureBase64: sign(null, payload, transportPrivateKey).toString("base64"),
    ...(authorityPrivateKey
      ? { authoritySignatureBase64: sign(null, payload, authorityPrivateKey).toString("base64") }
      : {}),
    expectedUid: UID,
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
      invokeCallable(publishIrohPairingPublicKey, UID, {
        deviceId: HOST_DEVICE_ID,
        roleId: "host",
        publicKeyBase64: rawEd25519PublicKey(host.publicKey).toString("base64"),
        nonce: "linux-host-key-nonce",
      }),
    ).resolves.toEqual({ ok: true, roleId: "host" });
    await expect(
      invokeCallable(publishIrohPairingRecord, UID, {
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

  it("admits an approved Linux App Check host without granting CloudVault escrow trust", async () => {
    const host = generateKeyPairSync("ed25519");
    const linuxAppId = "1:123:linux:route-test";
    store.set(`users/${UID}/linux_app_check_devices/${HOST_DEVICE_ID}`, {
      appId: linuxAppId,
      deviceId: HOST_DEVICE_ID,
      platform: "Linux",
      trustState: "approved",
    });
    expect(store.has(`users/${UID}/escrow_devices/${HOST_DEVICE_ID}`)).toBe(false);
    await expect(
      invokeCallableForApp(publishIrohPairingPublicKey, UID, linuxAppId, {
        deviceId: HOST_DEVICE_ID,
        roleId: "host",
        publicKeyBase64: rawEd25519PublicKey(host.publicKey).toString("base64"),
        nonce: "approved-linux-host-nonce",
      }),
    ).resolves.toEqual({ ok: true, roleId: "host" });
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
    expect(challenge).toMatchObject({
      proofKind: "bootstrap",
      requiresAuthorityProof: true,
      registrationGeneration: 1,
    });
    const canonicalPayload = Buffer.from(challenge.canonicalPayloadBase64, "base64").toString("utf8");
    expect(canonicalPayload).toContain("OpenBurnBar-IrohControllerRoute-v2\n");
    expect(canonicalPayload.indexOf("challengeNonce")).toBeLessThan(canonicalPayload.indexOf("proofKind"));
    expect(canonicalPayload.indexOf("proofKind")).toBeLessThan(canonicalPayload.indexOf("uid"));
    expect(canonicalPayload).toContain("9:bootstrap\n");
    const registration = await registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey);
    expect(registration).toMatchObject({
      ok: true,
      sourceDeviceId: SOURCE_DEVICE_ID,
      transportNodeId: fixture.transportNodeId,
      authorityPeerNodeId: fixture.authorityPeerNodeId,
      generation: 1,
    });

    const resolution = requireActiveRouteResolution(
      await invokeCallable(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID }),
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
  });

  it("renews an exact active tuple with transport proof only while preserving route identity", async () => {
    const fixture = seedTrustGraph();
    const bootstrap = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await registerChallenge(bootstrap, fixture.transport.privateKey, fixture.authority.privateKey);
    const routePath = `users/${UID}/iroh_pairing/${CONNECTION_ID}/controller_routes/${SOURCE_DEVICE_ID}`;
    const bootstrapRoute = store.get(routePath);
    const registeredAtMillis = bootstrapRoute?.registeredAtMillis;
    const shortenedExpiry = Date.now() + 1_000;
    store.set(routePath, { ...bootstrapRoute, expiresAtMillis: shortenedExpiry });

    const renewal = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    expect(renewal).toMatchObject({
      proofKind: "transport-renewal",
      requiresAuthorityProof: false,
      registrationGeneration: 1,
    });
    expect(Buffer.from(renewal.canonicalPayloadBase64, "base64").toString("utf8")).toContain("17:transport-renewal\n");
    await expect(registerChallenge(renewal, fixture.transport.privateKey)).resolves.toMatchObject({
      ok: true,
      generation: 1,
    });

    expect(store.get(routePath)).toMatchObject({
      status: "active",
      generation: 1,
      registeredAtMillis,
      transportNodeId: fixture.transportNodeId,
      authorityPeerNodeId: fixture.authorityPeerNodeId,
    });
    const route = requireRecord(store.get(routePath), "stored controller route");
    const expiresAtMillis = requireNumber(route.expiresAtMillis, "stored controller route expiresAtMillis");
    expect(expiresAtMillis).toEqual(expect.any(Number));
    expect(expiresAtMillis).toBeGreaterThan(shortenedExpiry);
  });

  it("requires a new bootstrap proof and generation when the transport tuple changes", async () => {
    const fixture = seedTrustGraph();
    const bootstrap = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await registerChallenge(bootstrap, fixture.transport.privateKey, fixture.authority.privateKey);
    const replacementTransport = generateKeyPairSync("ed25519");
    const replacementTransportNodeId = rawEd25519PublicKey(replacementTransport.publicKey).toString("hex");

    const rotation = await issueChallenge(fixture.authorityPeerNodeId, replacementTransportNodeId);
    expect(rotation).toMatchObject({
      proofKind: "bootstrap",
      requiresAuthorityProof: true,
      registrationGeneration: 2,
    });
    await expect(registerChallenge(rotation, replacementTransport.privateKey)).rejects.toMatchObject({
      code: "invalid-argument",
    });
    await expect(
      registerChallenge(rotation, replacementTransport.privateKey, fixture.authority.privateKey),
    ).resolves.toMatchObject({ ok: true, generation: 2, transportNodeId: replacementTransportNodeId });
  });

  it("cannot consume a renewal after revocation changes its eligibility", async () => {
    const fixture = seedTrustGraph();
    const bootstrap = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await registerChallenge(bootstrap, fixture.transport.privateKey, fixture.authority.privateKey);
    const renewal = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    const routePath = `users/${UID}/iroh_pairing/${CONNECTION_ID}/controller_routes/${SOURCE_DEVICE_ID}`;
    const eligibleRoute = requireRecord(store.get(routePath), "eligible controller route");
    const eligibleRegisteredAtMillis = requireNumber(
      eligibleRoute.registeredAtMillis,
      "eligible controller route registeredAtMillis",
    );
    store.set(routePath, { ...eligibleRoute, registeredAtMillis: eligibleRegisteredAtMillis + 1 });
    await expect(registerChallenge(renewal, fixture.transport.privateKey)).rejects.toMatchObject({ code: "aborted" });
    store.set(routePath, eligibleRoute ?? {});
    await invokeCallable(revokeIrohControllerRoute, UID, {
      sourceDeviceId: SOURCE_DEVICE_ID,
      connectionId: CONNECTION_ID,
      expectedUid: UID,
      nonce: "renewal-race-revoke-nonce",
    });

    await expect(registerChallenge(renewal, fixture.transport.privateKey)).rejects.toMatchObject({ code: "aborted" });
    const replacement = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    expect(replacement).toMatchObject({
      proofKind: "bootstrap",
      requiresAuthorityProof: true,
      registrationGeneration: 3,
    });
  });

  it("rejects a forged transport proof without consuming the challenge", async () => {
    const fixture = seedTrustGraph();
    const attacker = generateKeyPairSync("ed25519");
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await expect(registerChallenge(challenge, attacker.privateKey, fixture.authority.privateKey)).rejects.toMatchObject(
      {
        code: "permission-denied",
      },
    );
    expect(store.get(`users/${UID}/iroh_controller_route_challenges/${challenge.challengeId}`)?.status).toBe("pending");
    await expect(
      registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey),
    ).resolves.toMatchObject({ ok: true });
  });

  it("rejects a forged authority proof without consuming the challenge", async () => {
    const fixture = seedTrustGraph();
    const attacker = generateKeyPairSync("ed25519");
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await expect(registerChallenge(challenge, fixture.transport.privateKey, attacker.privateKey)).rejects.toMatchObject(
      { code: "permission-denied" },
    );
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
    await expect(
      invokeCallable(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID }),
    ).resolves.toMatchObject({ routes: [] });
    store.set(sourceDevicePath, {
      ...store.get(sourceDevicePath),
      peerNodeId: registered.authorityPeerNodeId,
    });
    const controllerPath = `users/${UID}/iroh_pairing/${CONNECTION_ID}/controllers/${registered.authorityPeerNodeId}`;
    store.set(controllerPath, { ...store.get(controllerPath), publicKeyBase64: randomBytes(32).toString("base64") });
    await expect(
      invokeCallable(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID }),
    ).resolves.toMatchObject({ routes: [] });

    store.clear();
    const expired = seedTrustGraph();
    const expiryChallenge = await issueChallenge(expired.authorityPeerNodeId, expired.transportNodeId);
    await registerChallenge(expiryChallenge, expired.transport.privateKey, expired.authority.privateKey);
    const routePath = `users/${UID}/iroh_pairing/${CONNECTION_ID}/controller_routes/${SOURCE_DEVICE_ID}`;
    store.set(routePath, { ...store.get(routePath), expiresAtMillis: Date.now() - 1 });
    await expect(
      invokeCallable(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID }),
    ).resolves.toMatchObject({ routes: [] });
  });

  it("returns empty for negative trust state but still rejects malformed active routes", async () => {
    await expect(
      invokeCallable(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID }),
    ).resolves.toMatchObject({ uid: UID, connectionId: CONNECTION_ID, routes: [] });

    const fixture = seedTrustGraph();
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey);
    const pairingPath = `users/${UID}/iroh_pairing/${CONNECTION_ID}`;
    store.set(pairingPath, {
      ...store.get(pairingPath),
      authorizedControllerDeviceIds: [SOURCE_DEVICE_ID, "other-phone"],
    });
    await expect(
      invokeCallable(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID }),
    ).resolves.toMatchObject({ routes: [] });

    store.set(pairingPath, {
      ...store.get(pairingPath),
      authorizedControllerDeviceIds: [SOURCE_DEVICE_ID],
      publishedAtMillis: Date.now() - 4 * 60 * 1000,
    });
    await expect(
      invokeCallable(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID }),
    ).resolves.toMatchObject({ routes: [] });
    const routePath = `users/${UID}/iroh_pairing/${CONNECTION_ID}/controller_routes/${SOURCE_DEVICE_ID}`;
    store.set(routePath, { ...store.get(routePath), transportNodeId: "malformed-node-id" });
    await expect(invokeCallable(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID })).rejects.toMatchObject(
      { code: "invalid-argument" },
    );
  });

  it("revokes durably by advancing the generation and blocks resolution", async () => {
    const fixture = seedTrustGraph();
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey);
    await expect(
      invokeCallable(revokeIrohControllerRoute, UID, {
        sourceDeviceId: SOURCE_DEVICE_ID,
        connectionId: CONNECTION_ID,
        expectedUid: UID,
        nonce: "revoke-nonce",
      }),
    ).resolves.toMatchObject({ ok: true, generation: 2 });
    await expect(
      invokeCallable(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID }),
    ).resolves.toMatchObject({ routes: [] });
  });

  it("tombstones an absent route so an outstanding first-generation challenge cannot register", async () => {
    const fixture = seedTrustGraph();
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await expect(
      invokeCallable(revokeIrohControllerRoute, UID, {
        sourceDeviceId: SOURCE_DEVICE_ID,
        connectionId: CONNECTION_ID,
        expectedUid: UID,
        nonce: "revoke-before-register-nonce",
      }),
    ).resolves.toMatchObject({ ok: true, generation: 1 });
    expect(store.get(`users/${UID}/iroh_pairing/${CONNECTION_ID}/controller_routes/${SOURCE_DEVICE_ID}`)).toMatchObject(
      {
        connectionId: CONNECTION_ID,
        sourceDeviceId: SOURCE_DEVICE_ID,
        status: "revoked",
        generation: 1,
      },
    );
    await expect(
      registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey),
    ).rejects.toMatchObject({ code: "aborted" });
  });

  it("tombstones the verified route when the host revokes its pairing", async () => {
    const fixture = seedTrustGraph();
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    await registerChallenge(challenge, fixture.transport.privateKey, fixture.authority.privateKey);
    await expect(
      invokeCallable(revokeIrohPairingRecord, UID, {
        deviceId: HOST_DEVICE_ID,
        connectionId: CONNECTION_ID,
        nonce: "host-pairing-revoke-nonce",
      }),
    ).resolves.toEqual({ ok: true, connectionId: CONNECTION_ID });
    expect(store.get(`users/${UID}/iroh_pairing/${CONNECTION_ID}/controller_routes/${SOURCE_DEVICE_ID}`)).toMatchObject(
      { status: "revoked", generation: 2 },
    );
    await expect(
      invokeCallable(resolveActiveIrohControllerRoutes, UID, { connectionId: CONNECTION_ID }),
    ).resolves.toMatchObject({ routes: [] });
  });

  it("issue challenge scopes every lookup to request.auth.uid", async () => {
    const fixture = seedTrustGraph();
    const before = snapshotTenantPaths(store, UID);
    await expect(
      invokeCallable(issueIrohControllerRouteChallenge, BOB_UID, {
        sourceDeviceId: SOURCE_DEVICE_ID,
        connectionId: CONNECTION_ID,
        authorityPeerNodeId: fixture.authorityPeerNodeId,
        transportNodeId: fixture.transportNodeId,
        expectedUid: BOB_UID,
        nonce: "attacker-nonce",
      }),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(snapshotTenantPaths(store, UID)).toEqual(before);
  });

  it("registration cannot consume a cross-user challenge", async () => {
    const fixture = seedTrustGraph();
    const challenge = await issueChallenge(fixture.authorityPeerNodeId, fixture.transportNodeId);
    const before = snapshotTenantPaths(store, UID);
    await expect(
      invokeCallable(registerIrohControllerRoute, BOB_UID, {
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
        expectedUid: BOB_UID,
      }),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(snapshotTenantPaths(store, UID)).toEqual(before);
  });

  it("resolution cannot read a cross-user route", async () => {
    seedTrustGraph();
    const before = snapshotTenantPaths(store, UID);
    await expect(
      invokeCallable(resolveActiveIrohControllerRoutes, BOB_UID, { connectionId: CONNECTION_ID }),
    ).resolves.toMatchObject({ uid: BOB_UID, connectionId: CONNECTION_ID, routes: [] });
    expect(snapshotTenantPaths(store, UID)).toEqual(before);
  });

  it("revocation cannot mutate a cross-user route", async () => {
    seedTrustGraph();
    const before = snapshotTenantPaths(store, UID);
    await expect(
      invokeCallable(revokeIrohControllerRoute, BOB_UID, {
        sourceDeviceId: SOURCE_DEVICE_ID,
        connectionId: CONNECTION_ID,
        expectedUid: BOB_UID,
        nonce: "attacker-revoke-nonce",
      }),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    expect(snapshotTenantPaths(store, UID)).toEqual(before);
  });

  it("rejects a stale expected account before any route mutation", async () => {
    const fixture = seedTrustGraph();
    const before = snapshotTenantPaths(store, UID);
    await expect(
      invokeCallable(issueIrohControllerRouteChallenge, UID, {
        sourceDeviceId: SOURCE_DEVICE_ID,
        connectionId: CONNECTION_ID,
        authorityPeerNodeId: fixture.authorityPeerNodeId,
        transportNodeId: fixture.transportNodeId,
        expectedUid: BOB_UID,
        nonce: "stale-account-nonce",
      }),
    ).rejects.toMatchObject({ code: "permission-denied" });
    expect(snapshotTenantPaths(store, UID)).toEqual(before);
  });
});
