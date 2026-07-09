import { beforeEach, describe, expect, it, vi } from "vitest";

import {
  __communityCallableTestExports,
  exportLookingGlassBundle,
  revokeCommunityParticipation,
} from "../community/callables.js";
import { COMMUNITY_SCHEMA_VERSION, CommunityPaths } from "../community/consent.js";
import type { CommunityWindowTotals } from "../types/generated/community.js";
import { requireNumberField, requireRecord, requireStringField } from "./support/communityTestGuards.js";
import { ALICE_UID, callableRequest, callableRunner, pathKeyedFirestore, seedDoc } from "./bola/callableBolaHarness.js";

const FRESH_SHARE_SNAPSHOT_UPDATED_AT = new Date().toISOString();
const store: Map<string, Record<string, unknown>> = vi.hoisted(() => new Map());
const { appendAuditEventRequired, storageSaveMock } = vi.hoisted(() => ({
  appendAuditEventRequired: vi.fn(async () => undefined),
  storageSaveMock: vi.fn(async (_data: Buffer, _options: { contentType: string }) => undefined),
}));

vi.mock("../resilienceHelpers.js", () => ({
  firestoreWithResilience: vi.fn((_label: string, fn: () => Promise<unknown>) => fn()),
}));

vi.mock("../callables/auditLog.js", () => ({
  appendAuditEventRequired,
  AUDIT_ACTIONS: { dataExport: "data_export" },
  auditActorLabel: () => "user:test",
}));

vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(store),
  };
});

vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({
    bucket: () => ({
      file: () => ({
        save: storageSaveMock,
        getSignedUrl: vi.fn(async () => ["https://signed.example/export.jsonl"]),
      }),
    }),
  }),
}));

function windowTotals(tokenScale: number): CommunityWindowTotals {
  const slot = (totalTokens: number) => ({ totalTokens, costUSD: totalTokens * 0.001 });
  return {
    today: slot(100 * tokenScale),
    "7d": slot(500 * tokenScale),
    "30d": slot(2000 * tokenScale),
    "90d": slot(5000 * tokenScale),
    all_time: slot(10000 * tokenScale),
  };
}

describe("exportLookingGlassBundle", () => {
  beforeEach(() => {
    store.clear();
    storageSaveMock.mockClear();
    vi.mocked(appendAuditEventRequired).mockReset();
    vi.mocked(appendAuditEventRequired).mockResolvedValue(undefined);
  });

  it("defaults to JSONL and records signedUrl, traceCount, format, and expiresIn", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), { l3LookingGlass: "granted" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t1`, { sessionId: "s1" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t2`, { sessionId: "s2" });

    const run = callableRunner(exportLookingGlassBundle);
    const result = requireRecord(await run(callableRequest(ALICE_UID, {})), "Looking Glass JSONL result");
    const signedUrl = requireStringField(result, "signedUrl");

    expect(signedUrl).toMatch(/^https:\/\//);
    expect(requireStringField(result, "downloadUrl")).toBe(signedUrl);
    expect(requireNumberField(result, "traceCount")).toBe(2);
    expect(requireStringField(result, "format")).toBe("jsonl");
    expect(requireNumberField(result, "expiresIn")).toBe(__communityCallableTestExports.SIGNED_URL_TTL_SECONDS);
    expect(storageSaveMock).toHaveBeenCalledWith(expect.any(Buffer), { contentType: "application/x-ndjson" });
  });

  it("writes Parquet bundles when requested", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), { l3LookingGlass: "granted" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t1`, {
      sessionId: "s1",
      model: "gpt-5.5",
      provider: "openai",
      purpose: "logic",
      corrected: false,
      totalTokens: 42,
      costUSD: 0.02,
      signals: ["file_edit"],
      recordedAt: "2026-07-09T00:00:00.000Z",
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
    });

    const run = callableRunner(exportLookingGlassBundle);
    const result = requireRecord(
      await run(callableRequest(ALICE_UID, { format: "parquet" })),
      "Looking Glass Parquet result",
    );

    expect(requireNumberField(result, "traceCount")).toBe(1);
    expect(requireStringField(result, "format")).toBe("parquet");
    expect(storageSaveMock).toHaveBeenCalledWith(expect.any(Buffer), {
      contentType: "application/vnd.apache.parquet",
    });
    const firstSaveCall = storageSaveMock.mock.calls.at(0);
    const parquetBuffer = firstSaveCall?.[0];
    expect(Buffer.isBuffer(parquetBuffer)).toBe(true);
    if (!Buffer.isBuffer(parquetBuffer)) throw new Error("Parquet export did not save a Buffer.");
    expect(parquetBuffer.subarray(0, 4).toString("utf8")).toBe("PAR1");
    expect(parquetBuffer.includes("recordedAt")).toBe(true);
    expect(parquetBuffer.includes("createdAt")).toBe(false);
  });

  it("rejects unknown export formats before writing storage", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), { l3LookingGlass: "granted" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t1`, { sessionId: "s1" });

    const run = callableRunner(exportLookingGlassBundle);
    await expect(run(callableRequest(ALICE_UID, { format: "csv" }))).rejects.toMatchObject({
      code: "invalid-argument",
    });
    expect(storageSaveMock).not.toHaveBeenCalled();
  });

  it("requires L3 consent", async () => {
    const run = callableRunner(exportLookingGlassBundle);
    await expect(run(callableRequest(ALICE_UID, {}))).rejects.toMatchObject({
      code: "permission-denied",
    });
  });

  it("does not write Storage bytes when required audit rejects", async () => {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), { l3LookingGlass: "granted" });
    seedDoc(store, `users/${ALICE_UID}/looking_glass_traces/t1`, { sessionId: "s1" });
    vi.mocked(appendAuditEventRequired).mockRejectedValueOnce(new Error("audit export failed"));

    const run = callableRunner(exportLookingGlassBundle);
    await expect(run(callableRequest(ALICE_UID, {}))).rejects.toThrow(/audit export failed/);

    expect(storageSaveMock).not.toHaveBeenCalled();
    expect(appendAuditEventRequired).toHaveBeenCalledTimes(1);
  });
});

describe("revokeCommunityParticipation", () => {
  beforeEach(() => {
    store.clear();
    vi.mocked(appendAuditEventRequired).mockReset();
    vi.mocked(appendAuditEventRequired).mockResolvedValue(undefined);
  });

  function seedParticipation(): void {
    seedDoc(store, CommunityPaths.consent(ALICE_UID), { l1Analytics: "granted", l2Rankings: "granted" });
    seedDoc(store, CommunityPaths.profile(ALICE_UID), {
      handle: "revoke_me",
      handleLower: "revoke_me",
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
    });
    seedDoc(store, CommunityPaths.shareSnapshot(ALICE_UID), {
      windows: windowTotals(1),
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
      updatedAt: FRESH_SHARE_SNAPSHOT_UPDATED_AT,
    });
    seedDoc(store, CommunityPaths.handleClaim("revoke_me"), { uid: ALICE_UID });
  }

  it("does not mutate community docs or release handle when required audit rejects", async () => {
    seedParticipation();
    vi.mocked(appendAuditEventRequired).mockRejectedValueOnce(new Error("audit unavailable"));

    const run = callableRunner(revokeCommunityParticipation);
    await expect(run(callableRequest(ALICE_UID, {}))).rejects.toThrow(/audit unavailable/);

    expect(store.has(CommunityPaths.profile(ALICE_UID))).toBe(true);
    expect(store.has(CommunityPaths.shareSnapshot(ALICE_UID))).toBe(true);
    expect(store.get(CommunityPaths.handleClaim("revoke_me"))).toEqual({ uid: ALICE_UID });
    expect(appendAuditEventRequired).toHaveBeenCalledTimes(1);
  });

  it("atomically releases the handle while deleting participation state", async () => {
    seedParticipation();

    const run = callableRunner(revokeCommunityParticipation);
    await run(callableRequest(ALICE_UID, {}));

    expect(store.has(CommunityPaths.profile(ALICE_UID))).toBe(false);
    expect(store.has(CommunityPaths.shareSnapshot(ALICE_UID))).toBe(false);
    expect(store.has(CommunityPaths.handleClaim("revoke_me"))).toBe(false);
    expect(store.get(CommunityPaths.consent(ALICE_UID))).toMatchObject({
      l2Rankings: "declined",
      l3LookingGlass: "declined",
      schemaVersion: COMMUNITY_SCHEMA_VERSION,
    });
  });
});
