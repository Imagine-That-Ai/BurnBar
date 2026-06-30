import { beforeEach, describe, expect, it, vi } from "vitest";

import { seedDoc } from "./bola/callableBolaHarness.js";

const mocks = vi.hoisted(() => ({
  fetchQuota: vi.fn(),
  retrieveCredential: vi.fn(),
}));

vi.mock("../secrets.js", () => ({
  retrieveCredential: mocks.retrieveCredential,
}));

vi.mock("../providers/openai.js", () => ({
  openaiAdapter: {
    provider: "openai",
    testCredential: vi.fn(),
    fetchQuota: mocks.fetchQuota,
  },
}));

import { providerAccountSecretRefPath, refreshUserProviderAccountQuota, type QuotaFirestoreLike } from "../quota.js";

const UID = "quota-secret-user";
const ACCOUNT_ID = "openai_default";
const DEMO_ACCOUNT_ID = "demo_android_openai";
const NOW = "2026-06-24T17:00:00.000Z";

function seedProviderAccount(store: Map<string, Record<string, unknown>>, providerID = "openai") {
  seedDoc(store, `users/${UID}/provider_accounts/${ACCOUNT_ID}`, {
    id: ACCOUNT_ID,
    providerID,
    label: "OpenAI",
    status: "connected",
    credentialKind: "bearer",
    storageScope: "cloud_refreshable",
    redactedLabel: "openai_***test",
    isDefault: true,
    sortKey: 0,
    schemaVersion: 1,
    createdAt: NOW,
    updatedAt: NOW,
  });
}

function seedSecretRef(store: Map<string, Record<string, unknown>>, providerID = "openai") {
  seedDoc(store, providerAccountSecretRefPath(UID, ACCOUNT_ID), {
    uid: UID,
    providerID,
    accountID: ACCOUNT_ID,
    secretVersionName: "projects/test/secrets/openai-default/versions/1",
    createdAt: NOW,
    updatedAt: NOW,
  });
}

function seedEntitlement(store: Map<string, Record<string, unknown>>, entitlementID = "burnbar_pro", productID = "com.openburnbar.pro.monthly") {
  seedDoc(store, `users/${UID}/entitlements/${entitlementID}`, {
    active: true,
    productID,
    expiresAt: "2999-01-01T00:00:00.000Z",
  });
}

function quotaSnapshot() {
  return {
    provider: "openai",
    sourceKind: "provider",
    sourceId: "usage",
    fetchedAt: NOW,
    source: "OpenAI",
    confidence: "high",
    buckets: [],
    updatedAt: NOW,
    schemaVersion: 2,
  };
}

function quotaTestFirestore(store: Map<string, Record<string, unknown>>): QuotaFirestoreLike {
  const writeDoc = (path: string, data: object, merge = false) => {
    const next = Object.fromEntries(Object.entries(data));
    store.set(path, merge ? { ...store.get(path), ...next } : next);
  };
  const doc = (path: string) => ({
    get: async () => {
      const data = store.get(path);
      return {
        exists: data !== undefined,
        data: () => data,
        get: (field: string) => data?.[field],
      };
    },
    set: async (data: object, options?: { merge: boolean }) => {
      writeDoc(path, data, options?.merge === true);
    },
    update: async (data: object) => {
      writeDoc(path, data, true);
    },
  });
  return {
    doc,
    runTransaction: async (fn) =>
      fn({
        get: (ref) => ref.get(),
        set: (ref, data, options) => ref.set(data, options),
        update: (ref, data) => ref.update(data),
      }),
  };
}

describe("provider account quota secret binding", () => {
  beforeEach(() => {
    mocks.fetchQuota.mockReset();
    mocks.retrieveCredential.mockReset();
    mocks.retrieveCredential.mockResolvedValue("bound-secret");
    mocks.fetchQuota.mockResolvedValue({ ok: true, snapshot: quotaSnapshot() });
  });

  it("rejects a private secret ref whose provider does not match the account provider", async () => {
    const store = new Map<string, Record<string, unknown>>();
    seedProviderAccount(store, "openai");
    seedSecretRef(store, "kimi");
    seedEntitlement(store);

    const db = quotaTestFirestore(store);

    await expect(refreshUserProviderAccountQuota(db, UID, ACCOUNT_ID)).rejects.toThrow(
      /Secret reference does not match provider/,
    );
    expect(mocks.retrieveCredential).not.toHaveBeenCalled();
    expect(mocks.fetchQuota).not.toHaveBeenCalled();
  });

  it("refreshes quota when the private secret ref is bound to the same provider", async () => {
    const store = new Map<string, Record<string, unknown>>();
    seedProviderAccount(store, "openai");
    seedSecretRef(store, "openai");
    seedEntitlement(store);

    const db = quotaTestFirestore(store);

    const snapshot = await refreshUserProviderAccountQuota(db, UID, ACCOUNT_ID);

    expect(mocks.retrieveCredential).toHaveBeenCalledWith("projects/test/secrets/openai-default/versions/1");
    expect(mocks.fetchQuota).toHaveBeenCalledWith("bound-secret", ACCOUNT_ID, {
      endpointProfileID: undefined,
      region: undefined,
      tokenPlanTier: undefined,
      tokenPlanBillingCycle: undefined,
      authMethodID: undefined,
    });
    expect(snapshot).toMatchObject({
      providerID: "openai",
      accountID: ACCOUNT_ID,
      accountStorageScope: "cloud_refreshable",
    });
    expect(store.get(`users/${UID}/quota_snapshots/openai_${ACCOUNT_ID}_usage`)).toMatchObject({
      providerID: "openai",
      accountID: ACCOUNT_ID,
    });
  });

  it("refreshes quota for an Ultra-only entitlement", async () => {
    const store = new Map<string, Record<string, unknown>>();
    seedProviderAccount(store, "openai");
    seedSecretRef(store, "openai");
    seedEntitlement(store, "burnbar_ultra", "com.openburnbar.ultra.monthly");

    const db = quotaTestFirestore(store);

    const snapshot = await refreshUserProviderAccountQuota(db, UID, ACCOUNT_ID);

    expect(mocks.retrieveCredential).toHaveBeenCalledWith("projects/test/secrets/openai-default/versions/1");
    expect(mocks.fetchQuota).toHaveBeenCalledOnce();
    expect(snapshot).toMatchObject({
      providerID: "openai",
      accountID: ACCOUNT_ID,
      accountStorageScope: "cloud_refreshable",
    });
  });

  it("does not refresh seeded demo provider accounts", async () => {
    const store = new Map<string, Record<string, unknown>>();
    seedDoc(store, `users/${UID}/provider_accounts/${DEMO_ACCOUNT_ID}`, {
      id: DEMO_ACCOUNT_ID,
      providerID: "openai",
      label: "OpenAI demo",
      status: "connected",
      credentialKind: "token",
      storageScope: "cloud_refreshable",
      redactedLabel: "openai_***demo",
      isDefault: false,
      sortKey: 10,
      schemaVersion: 1,
      createdAt: NOW,
      updatedAt: NOW,
      demo: true,
    });

    const db = quotaTestFirestore(store);

    await expect(refreshUserProviderAccountQuota(db, UID, DEMO_ACCOUNT_ID)).resolves.toBeNull();
    expect(mocks.retrieveCredential).not.toHaveBeenCalled();
    expect(mocks.fetchQuota).not.toHaveBeenCalled();
    expect(store.has(`users/${UID}/quota_snapshots/openai_${DEMO_ACCOUNT_ID}_usage`)).toBe(false);
  });
});
