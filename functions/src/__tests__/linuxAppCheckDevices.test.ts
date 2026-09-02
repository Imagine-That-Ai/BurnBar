import { generateKeyPairSync, sign } from "node:crypto";

import { beforeEach, describe, expect, it, vi } from "vitest";

const { store, highRisk, actionProof, trustedDevice, rateLimit } = vi.hoisted(() => ({
  store: new Map<string, Record<string, unknown>>(),
  highRisk: vi.fn(async () => ({ nonceConsumed: true })),
  actionProof: vi.fn(async () => undefined),
  trustedDevice: vi.fn(async (_uid: string, deviceId: string) => {
    if (deviceId.startsWith("bob-")) {
      throw Object.assign(new Error("manager device belongs to another account"), { code: "permission-denied" });
    }
    return { deviceId, platform: "iPadOS" };
  }),
  rateLimit: vi.fn(async () => undefined),
}));

type Ref = { path: string };
type TestCallableRequest = {
  auth: { uid: string; token: Record<string, unknown>; rawToken: string };
  app: {
    appId: string;
    token: {
      app_id: string;
      aud: string[];
      exp: number;
      iat: number;
      iss: string;
      sub: string;
    };
  };
  data: Record<string, unknown>;
  rawRequest: { headers: Record<string, string> };
  acceptsStreaming: false;
};

function snapshot(path: string) {
  const data = store.get(path);
  return {
    id: path.split("/").at(-1),
    exists: data !== undefined,
    get: (field: string) => data?.[field],
    data: () => data,
    ref: { path },
  };
}

function write(path: string, data: Record<string, unknown>, merge = false): void {
  store.set(path, merge ? { ...(store.get(path) ?? {}), ...data } : { ...data });
}

vi.mock("../adminRuntime.js", () => ({
  db: {
    doc(path: string) {
      return {
        path,
        get: async () => snapshot(path),
        set: async (data: Record<string, unknown>, options?: { merge?: boolean }) => write(path, data, options?.merge),
      };
    },
    collection(path: string) {
      const documents = (limit: number, newestFirst: boolean, trustState?: string) => {
        const entries = [...store].filter(
          ([candidate, data]) =>
            candidate.startsWith(`${path}/`) && (trustState === undefined || data.trustState === trustState),
        );
        if (newestFirst) {
          entries.sort((left, right) => {
            const createdOrder = Number(right[1].createdAtMillis ?? 0) - Number(left[1].createdAtMillis ?? 0);
            return createdOrder === 0 ? right[0].localeCompare(left[0]) : createdOrder;
          });
        }
        return entries.slice(0, limit).map(([candidate]) => snapshot(candidate));
      };
      type Query = {
        orderBy(field: unknown, direction: string): Query;
        limit(limit: number): { get(): Promise<{ docs: ReturnType<typeof snapshot>[] }> };
      };
      const query = (trustState?: string, newestFirst = false): Query => ({
        orderBy() {
          return query(trustState, true);
        },
        limit(limit: number) {
          return { get: async () => ({ docs: documents(limit, newestFirst, trustState) }) };
        },
      });
      return {
        where(field: string, operator: string, value: string) {
          expect(field).toBe("trustState");
          expect(operator).toBe("==");
          return query(value);
        },
        orderBy() {
          return query(undefined, true);
        },
        limit(limit: number) {
          return { get: async () => ({ docs: documents(limit, false) }) };
        },
      };
    },
    runTransaction: async (handler: (transaction: unknown) => Promise<unknown>) =>
      handler({
        get: async (ref: Ref) => snapshot(ref.path),
        create: (ref: Ref, data: Record<string, unknown>) => {
          if (store.has(ref.path)) throw new Error("already exists");
          write(ref.path, data);
        },
        set: (ref: Ref, data: Record<string, unknown>, options?: { merge?: boolean }) =>
          write(ref.path, data, options?.merge),
        update: (ref: Ref, data: Record<string, unknown>) => write(ref.path, data, true),
      }),
  },
}));

vi.mock("firebase-admin/firestore", () => ({
  FieldPath: { documentId: () => ({ __documentID: true }) },
  FieldValue: { serverTimestamp: () => ({ __serverTimestamp: true }) },
  Timestamp: { fromMillis: (millis: number) => ({ toMillis: () => millis }) },
}));

const APP_ID = "1:123:linux:production";

vi.mock("../config.js", () => ({
  getConfig: () => ({ enforceAppCheck: true, linuxAppCheckAppID: "1:123:linux:production" }),
}));
vi.mock("../logging.js", () => ({
  logInfo: vi.fn(),
  onCallProduction: (_name: string, _options: unknown, handler: (request: unknown) => Promise<unknown>) => ({
    run: handler,
  }),
}));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));
vi.mock("../appCheckAttestation.js", () => ({
  appCheckTrustClassForAppId: (appId: string | undefined) =>
    appId?.includes(":ios:") ? "apple_attested" : appId?.includes(":android:") ? "android_play_integrity" : "unknown",
  enforceHighRiskComputerUseCallableWithNonce: highRisk,
  readAppIdFromCallableRequest: (request: { app?: { appId?: string } }) => request.app?.appId,
}));
vi.mock("../callables/computerUseSecurityFirestore.js", () => ({
  requireTrustedDeviceActionProof: actionProof,
  requireTrustedEscrowDevice: trustedDevice,
}));
vi.mock("../callables/publicRateLimit.js", () => ({ checkPublicHttpEndpointRateLimit: rateLimit }));

import {
  approveLinuxAppCheckDevice,
  consumeLinuxAppCheckChallenge,
  issueLinuxAppCheckChallenge,
  listLinuxAppCheckDevices,
  registerLinuxAppCheckDevice,
  requireApprovedLinuxAppCheckIrohHost,
  revokeLinuxAppCheckDevice,
} from "../callables/linuxAppCheckDevices.js";
import {
  LINUX_APP_CHECK_ENROLLMENT_DOMAIN,
  deriveLinuxAppCheckDeviceId,
  linuxAppCheckEnrollmentPayload,
} from "../callables/linuxAppCheckDeviceCrypto.js";
import { BOB_UID, callableRunner, tier2CallableProof } from "./bola/callableBolaHarness.js";

const UID = "linux-owner";
const APPROVER_ID = "trusted-ipad";

function rawPublicKey(key: ReturnType<typeof generateKeyPairSync>["publicKey"]): Buffer {
  return key.export({ format: "der", type: "spki" }).subarray(-32);
}

function request(data: Record<string, unknown>, appId = "1:123:ios:native"): TestCallableRequest {
  return {
    auth: { uid: UID, token: {}, rawToken: "test-id-token" },
    app: {
      appId,
      token: {
        app_id: appId,
        aud: ["projects/123"],
        exp: 4_102_444_800,
        iat: 1_700_000_000,
        iss: "https://firebaseappcheck.googleapis.com/123",
        sub: appId,
      },
    },
    data,
    rawRequest: { headers: {} },
    acceptsStreaming: false,
  };
}

function invoke(callable: unknown, data: Record<string, unknown>, appId?: string): Promise<unknown> {
  return callableRunner(callable)(request(data, appId));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function requireRecord(value: unknown, label: string): Record<string, unknown> {
  if (isRecord(value)) return value;
  throw new Error(`${label} must be an object`);
}

function requireString(value: unknown, label: string): string {
  if (typeof value === "string") return value;
  throw new Error(`${label} must be a string`);
}

function requireChallenge(value: unknown): { challengeId: string; canonicalPayloadBase64: string } {
  const record = requireRecord(value, "Linux App Check challenge");
  return {
    challengeId: requireString(record.challengeId, "Linux App Check challengeId"),
    canonicalPayloadBase64: requireString(record.canonicalPayloadBase64, "Linux App Check canonicalPayloadBase64"),
  };
}

function requireDeviceList(value: unknown): { devices: Array<Record<string, unknown>> } {
  const record = requireRecord(value, "Linux App Check device list");
  const devices = record.devices;
  if (!Array.isArray(devices)) throw new Error("Linux App Check device list must include devices");
  return { devices: devices.map((device, index) => requireRecord(device, `Linux App Check device ${index}`)) };
}

function enrollment(deviceName = "Workstation", uid = UID) {
  const key = generateKeyPairSync("ed25519");
  const publicKeyBase64 = rawPublicKey(key.publicKey).toString("base64");
  const deviceId = deriveLinuxAppCheckDeviceId(Buffer.from(publicKeyBase64, "base64"));
  const issuedAtMillis = Date.now();
  const payload = linuxAppCheckEnrollmentPayload({
    appId: APP_ID,
    deviceId,
    publicKeyBase64,
    issuedAtMillis,
    uid,
  });
  return {
    key,
    data: {
      appId: APP_ID,
      deviceId,
      deviceName,
      issuedAtMillis,
      publicKeyBase64,
      signatureBase64: sign(null, payload, key.privateKey).toString("base64"),
    },
  };
}

describe("Linux App Check approved-device lifecycle", () => {
  beforeEach(() => {
    store.clear();
    highRisk.mockClear();
    actionProof.mockClear();
    trustedDevice.mockClear();
    rateLimit.mockClear();
  });

  it("uses the exact daemon-owned enrollment wire format", () => {
    const bytes = linuxAppCheckEnrollmentPayload({
      uid: "u",
      deviceId: "linux_key",
      appId: APP_ID,
      publicKeyBase64: "base64-key",
      issuedAtMillis: 123,
    });
    expect(bytes.toString("utf8")).toBe(
      `${LINUX_APP_CHECK_ENROLLMENT_DOMAIN}\nu\nlinux_key\n${APP_ID}\nbase64-key\n123`,
    );
    expect(bytes.at(-1)).not.toBe(0x0a);
  });

  it("registers only a fresh self-signed key-derived pending identity without granting escrow trust", async () => {
    const fixture = enrollment();
    await expect(invoke(registerLinuxAppCheckDevice, fixture.data, undefined)).resolves.toMatchObject({
      ok: true,
      deviceId: fixture.data.deviceId,
      trustState: "pending",
    });
    expect(store.get(`users/${UID}/linux_app_check_devices/${fixture.data.deviceId}`)).toMatchObject({
      appId: APP_ID,
      deviceId: fixture.data.deviceId,
      deviceName: "Workstation",
      platform: "Linux",
      publicKeyBase64: fixture.data.publicKeyBase64,
      trustState: "pending",
    });
    expect([...store.keys()].some((path) => path.includes("/escrow_devices/"))).toBe(false);
    expect(rateLimit).toHaveBeenCalledWith("registerLinuxAppCheckDevice", UID);

    await expect(
      invoke(registerLinuxAppCheckDevice, { ...fixture.data, signatureBase64: Buffer.alloc(64).toString("base64") }),
    ).rejects.toMatchObject({ code: "unauthenticated" });
    await expect(
      invoke(registerLinuxAppCheckDevice, { ...fixture.data, deviceId: "linux_attacker" }),
    ).rejects.toMatchObject({ code: "invalid-argument" });
    await expect(
      invoke(registerLinuxAppCheckDevice, { ...fixture.data, issuedAtMillis: Date.now() - 6 * 60 * 1000 }),
    ).rejects.toMatchObject({ code: "failed-precondition" });

    write(`users/${UID}/linux_app_check_devices/${fixture.data.deviceId}`, { trustState: "revoked" }, true);
    await expect(invoke(registerLinuxAppCheckDevice, fixture.data)).rejects.toMatchObject({
      code: "failed-precondition",
      details: { reason: "linux_device_revoked" },
    });

    const other = enrollment();
    write(`users/${UID}/linux_app_check_devices/${other.data.deviceId}`, {
      appId: APP_ID,
      deviceId: other.data.deviceId,
      publicKeyBase64: fixture.data.publicKeyBase64,
      trustState: "pending",
    });
    await expect(invoke(registerLinuxAppCheckDevice, other.data)).rejects.toMatchObject({
      code: "permission-denied",
      details: { reason: "linux_device_key_mismatch" },
    });
  });

  it("requires explicit trusted-native approval and an action proof", async () => {
    const fixture = enrollment();
    await invoke(registerLinuxAppCheckDevice, fixture.data);
    await expect(
      invoke(approveLinuxAppCheckDevice, {
        deviceId: fixture.data.deviceId,
        approverDeviceId: APPROVER_ID,
        nonce: "n".repeat(32),
        actionProof: { signed: true },
      }),
    ).resolves.toMatchObject({ ok: true, trustState: "approved", alreadyInState: false });
    expect(highRisk).toHaveBeenCalledOnce();
    expect(trustedDevice).toHaveBeenCalledWith(UID, APPROVER_ID, expect.any(Set));
    expect(actionProof).toHaveBeenCalledWith(
      expect.objectContaining({
        uid: UID,
        deviceId: APPROVER_ID,
        actionKind: "linux_app_check_device_approve",
        subjectId: fixture.data.deviceId,
        approve: true,
      }),
    );
    expect(store.get(`users/${UID}/linux_app_check_devices/${fixture.data.deviceId}`)).toMatchObject({
      trustState: "approved",
      approvedByDeviceId: APPROVER_ID,
    });
  });

  it("issues an opaque challenge only to approved keys and atomically consumes a valid signature once", async () => {
    const fixture = enrollment();
    await invoke(registerLinuxAppCheckDevice, fixture.data);
    await expect(
      invoke(issueLinuxAppCheckChallenge, { appId: APP_ID, deviceId: fixture.data.deviceId }, undefined),
    ).rejects.toMatchObject({
      code: "permission-denied",
      details: { reason: "linux_device_approval_required" },
    });
    write(`users/${UID}/linux_app_check_devices/${fixture.data.deviceId}`, { trustState: "revoked" }, true);
    await expect(
      invoke(issueLinuxAppCheckChallenge, { appId: APP_ID, deviceId: fixture.data.deviceId }, undefined),
    ).rejects.toMatchObject({
      code: "permission-denied",
      details: { reason: "linux_device_revoked" },
    });
    write(`users/${UID}/linux_app_check_devices/${fixture.data.deviceId}`, { trustState: "approved" }, true);
    const challenge = requireChallenge(
      await invoke(issueLinuxAppCheckChallenge, { appId: APP_ID, deviceId: fixture.data.deviceId }, undefined),
    );
    expect(rateLimit).toHaveBeenLastCalledWith("issueLinuxAppCheckChallenge", UID);
    const signatureBase64 = sign(
      null,
      Buffer.from(challenge.canonicalPayloadBase64, "base64"),
      fixture.key.privateKey,
    ).toString("base64");
    await expect(
      consumeLinuxAppCheckChallenge({
        appId: APP_ID,
        challengeId: challenge.challengeId,
        deviceId: fixture.data.deviceId,
        signatureBase64,
        uid: UID,
      }),
    ).resolves.toBeUndefined();
    expect(store.get(`users/${UID}/linux_app_check_challenges/${challenge.challengeId}`)?.status).toBe("consumed");
    await expect(
      consumeLinuxAppCheckChallenge({
        appId: APP_ID,
        challengeId: challenge.challengeId,
        deviceId: fixture.data.deviceId,
        signatureBase64,
        uid: UID,
      }),
    ).rejects.toMatchObject({ code: "unauthenticated" });
  });

  it("rejects forged, expired, revoked, cross-device, and tampered challenge consumption", async () => {
    const fixture = enrollment();
    await invoke(registerLinuxAppCheckDevice, fixture.data);
    const devicePath = `users/${UID}/linux_app_check_devices/${fixture.data.deviceId}`;
    write(devicePath, { trustState: "approved" }, true);
    const challenge = requireChallenge(
      await invoke(issueLinuxAppCheckChallenge, { appId: APP_ID, deviceId: fixture.data.deviceId }, undefined),
    );
    const challengePath = `users/${UID}/linux_app_check_challenges/${challenge.challengeId}`;
    const validSignature = sign(
      null,
      Buffer.from(challenge.canonicalPayloadBase64, "base64"),
      fixture.key.privateKey,
    ).toString("base64");
    await expect(
      consumeLinuxAppCheckChallenge({
        appId: APP_ID,
        challengeId: challenge.challengeId,
        deviceId: fixture.data.deviceId,
        signatureBase64: Buffer.alloc(64).toString("base64"),
        uid: UID,
      }),
    ).rejects.toMatchObject({ code: "unauthenticated" });
    write(challengePath, { canonicalPayloadBase64: "dGFtcGVyZWQ=" }, true);
    await expect(
      consumeLinuxAppCheckChallenge({
        appId: APP_ID,
        challengeId: challenge.challengeId,
        deviceId: fixture.data.deviceId,
        signatureBase64: validSignature,
        uid: UID,
      }),
    ).rejects.toMatchObject({ code: "failed-precondition" });
    write(challengePath, { canonicalPayloadBase64: challenge.canonicalPayloadBase64, expiresAtMillis: 1 }, true);
    await expect(
      consumeLinuxAppCheckChallenge({
        appId: APP_ID,
        challengeId: challenge.challengeId,
        deviceId: fixture.data.deviceId,
        signatureBase64: validSignature,
        uid: UID,
      }),
    ).rejects.toMatchObject({ code: "unauthenticated" });
    write(challengePath, { expiresAtMillis: Date.now() + 60_000 }, true);
    write(devicePath, { trustState: "revoked" }, true);
    await expect(
      consumeLinuxAppCheckChallenge({
        appId: APP_ID,
        challengeId: challenge.challengeId,
        deviceId: fixture.data.deviceId,
        signatureBase64: validSignature,
        uid: UID,
      }),
    ).rejects.toMatchObject({
      code: "permission-denied",
      details: { reason: "linux_device_revoked" },
    });
  });

  it("returns stable challenge-consumption reasons for every permanent device rejection", async () => {
    const fixture = enrollment();
    await invoke(registerLinuxAppCheckDevice, fixture.data);
    const devicePath = `users/${UID}/linux_app_check_devices/${fixture.data.deviceId}`;
    write(devicePath, { trustState: "approved" }, true);
    const challenge = requireChallenge(
      await invoke(issueLinuxAppCheckChallenge, { appId: APP_ID, deviceId: fixture.data.deviceId }, undefined),
    );
    const consume = () =>
      consumeLinuxAppCheckChallenge({
        appId: APP_ID,
        challengeId: challenge.challengeId,
        deviceId: fixture.data.deviceId,
        signatureBase64: sign(
          null,
          Buffer.from(challenge.canonicalPayloadBase64, "base64"),
          fixture.key.privateKey,
        ).toString("base64"),
        uid: UID,
      });

    store.delete(devicePath);
    await expect(consume()).rejects.toMatchObject({
      details: { reason: "linux_device_not_registered" },
    });

    write(devicePath, { ...fixture.data, trustState: "revoked" });
    await expect(consume()).rejects.toMatchObject({
      details: { reason: "linux_device_revoked" },
    });

    write(devicePath, { ...fixture.data, trustState: "unknown" });
    await expect(consume()).rejects.toMatchObject({
      details: { reason: "linux_device_invalid_trust_state" },
    });

    write(devicePath, { ...fixture.data, appId: "1:123:linux:other", trustState: "approved" });
    await expect(consume()).rejects.toMatchObject({
      details: { reason: "linux_device_record_mismatch" },
    });

    write(devicePath, { ...fixture.data, publicKeyBase64: "not-base64", trustState: "approved" });
    await expect(consume()).rejects.toMatchObject({
      details: { reason: "linux_device_record_mismatch" },
    });
  });

  it("lists public review material and revokes without ever returning private material", async () => {
    const fixture = enrollment("Linux Desktop");
    await invoke(registerLinuxAppCheckDevice, fixture.data);
    const listed = requireDeviceList(await invoke(listLinuxAppCheckDevices, { approverDeviceId: APPROVER_ID }));
    expect(listed.devices).toEqual([
      expect.objectContaining({
        deviceId: fixture.data.deviceId,
        deviceName: "Linux Desktop",
        publicKeyBase64: fixture.data.publicKeyBase64,
        safetyFingerprint: expect.any(String),
        trustState: "pending",
      }),
    ]);
    expect(JSON.stringify(listed)).not.toContain("private");
    await expect(
      invoke(revokeLinuxAppCheckDevice, {
        deviceId: fixture.data.deviceId,
        approverDeviceId: APPROVER_ID,
        nonce: "r".repeat(32),
        actionProof: { signed: true },
      }),
    ).resolves.toMatchObject({ trustState: "revoked", alreadyInState: false });
    await expect(
      invoke(approveLinuxAppCheckDevice, {
        deviceId: fixture.data.deviceId,
        approverDeviceId: APPROVER_ID,
        nonce: "a".repeat(32),
        actionProof: { signed: true },
      }),
    ).rejects.toMatchObject({ code: "failed-precondition" });
  });

  it("keeps an older pending identity visible behind more than 100 newer terminal records", async () => {
    const collection = `users/${UID}/linux_app_check_devices`;
    for (let index = 0; index < 101; index += 1) {
      const trustState = index % 2 === 0 ? "approved" : "revoked";
      write(`${collection}/${trustState}-${index}`, {
        deviceId: `${trustState}-${index}`,
        trustState,
        createdAtMillis: 1_000 + index,
      });
    }
    write(`${collection}/rotated-pending`, {
      deviceId: "rotated-pending",
      deviceName: "Rotated workstation",
      trustState: "pending",
      createdAtMillis: 1,
    });

    const listed = requireDeviceList(await invoke(listLinuxAppCheckDevices, { approverDeviceId: APPROVER_ID }));

    expect(listed.devices).toHaveLength(100);
    expect(listed.devices[0]).toMatchObject({ deviceId: "rotated-pending", trustState: "pending" });
    expect(listed.devices.some((device) => device.deviceId === "approved-0")).toBe(false);
  });

  it("keeps the newest rotated identity visible when more than 100 devices are pending", async () => {
    const collection = `users/${UID}/linux_app_check_devices`;
    for (let index = 0; index < 101; index += 1) {
      write(`${collection}/pending-${index.toString().padStart(3, "0")}`, {
        deviceId: `pending-${index}`,
        trustState: "pending",
        createdAtMillis: 1_000 + index,
      });
    }
    write(`${collection}/rotated-newest`, {
      deviceId: "rotated-newest",
      deviceName: "Rotated workstation",
      trustState: "pending",
      createdAtMillis: 10_000,
    });

    const listed = requireDeviceList(await invoke(listLinuxAppCheckDevices, { approverDeviceId: APPROVER_ID }));

    expect(listed.devices).toHaveLength(100);
    expect(listed.devices[0]).toMatchObject({ deviceId: "rotated-newest", trustState: "pending" });
    expect(listed.devices.some((device) => device.deviceId === "pending-0")).toBe(false);
  });

  it("admits only approved exact-app Linux records to the iroh host root", async () => {
    const fixture = enrollment();
    await invoke(registerLinuxAppCheckDevice, fixture.data);
    await expect(
      requireApprovedLinuxAppCheckIrohHost(request({}, APP_ID), UID, fixture.data.deviceId),
    ).rejects.toMatchObject({ code: "permission-denied" });
    write(`users/${UID}/linux_app_check_devices/${fixture.data.deviceId}`, { trustState: "approved" }, true);
    await expect(
      requireApprovedLinuxAppCheckIrohHost(request({}, APP_ID), UID, fixture.data.deviceId),
    ).resolves.toEqual({ deviceId: fixture.data.deviceId, platform: "Linux" });
    await expect(
      requireApprovedLinuxAppCheckIrohHost(request({}, "1:123:linux:evil"), UID, fixture.data.deviceId),
    ).rejects.toMatchObject({ code: "permission-denied" });
  });

  it("rejects cross-user App Check device operations without victim side effects", async () => {
    const nativeRunner = (callable: unknown) => {
      const run = callableRunner(callable);
      return (candidate: unknown) => {
        const app = requireRecord(Reflect.get(requireRecord(candidate, "callable request"), "app"), "callable app");
        Reflect.set(app, "appId", "1:123:ios:native");
        return run(candidate);
      };
    };
    const victimEnrollment = enrollment("Victim workstation", BOB_UID);

    await tier2CallableProof(store, {
      exportedName: "registerLinuxAppCheckDevice",
      run: callableRunner(registerLinuxAppCheckDevice),
      payload: victimEnrollment.data,
      expectedCode: "unauthenticated",
      strictCode: true,
    });
    await tier2CallableProof(store, {
      exportedName: "issueLinuxAppCheckChallenge",
      run: callableRunner(issueLinuxAppCheckChallenge),
      payload: { appId: APP_ID, deviceId: "bob-device" },
      expectedCode: "permission-denied",
      strictCode: true,
    });
    await tier2CallableProof(store, {
      exportedName: "listLinuxAppCheckDevices",
      run: nativeRunner(listLinuxAppCheckDevices),
      payload: { approverDeviceId: "bob-approverDeviceId" },
      expectedCode: "permission-denied",
      strictCode: true,
    });
    for (const [exportedName, callable] of [
      ["approveLinuxAppCheckDevice", approveLinuxAppCheckDevice],
      ["revokeLinuxAppCheckDevice", revokeLinuxAppCheckDevice],
    ] as const) {
      await tier2CallableProof(store, {
        exportedName,
        run: nativeRunner(callable),
        payload: {
          deviceId: "bob-device",
          approverDeviceId: APPROVER_ID,
          nonce: "b".repeat(32),
          actionProof: { signed: true },
        },
        // Restates (never overrides) the generated BOLA ledger; the coverage
        // validator requires the measured code to be named in this file.
        expectedCode: "not-found",
        strictCode: true,
      });
    }
  });
});
