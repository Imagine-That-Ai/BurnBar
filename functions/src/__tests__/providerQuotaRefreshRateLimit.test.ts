import { beforeEach, describe, expect, it, vi } from "vitest";

import { ALICE_UID, callableRequest, callableRunner, pathKeyedFirestore, seedDoc } from "./bola/callableBolaHarness.js";

const mocks = vi.hoisted(() => ({
  store: new Map<string, Record<string, unknown>>(),
  refreshUserProviderAccountQuota: vi.fn(),
  refreshUserProviderQuota: vi.fn(),
}));

vi.mock("../adminRuntime.js", () => ({ db: pathKeyedFirestore(mocks.store) }));
vi.mock("../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
  assertAppCheck: vi.fn(),
}));
vi.mock("../quota.js", () => ({
  refreshUserProviderAccountQuota: mocks.refreshUserProviderAccountQuota,
  refreshUserProviderQuota: mocks.refreshUserProviderQuota,
}));

const ACCOUNT_ID = "openai_default";
const NOW = "2026-06-25T09:30:00.000Z";

function seedProviderAccount(accountID = ACCOUNT_ID) {
  seedDoc(mocks.store, `users/${ALICE_UID}/provider_accounts/${accountID}`, {
    id: accountID,
    providerID: "openai",
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

async function runAccountRefresh(accountID = ACCOUNT_ID): Promise<unknown> {
  const mod = await import("../callables/providerAccounts.js");
  return callableRunner(mod.refreshProviderAccountQuota)(callableRequest(ALICE_UID, { accountID }));
}

describe("refreshProviderAccountQuota rate limiting", () => {
  beforeEach(() => {
    mocks.store.clear();
    mocks.refreshUserProviderAccountQuota.mockReset();
    mocks.refreshUserProviderQuota.mockReset();
    mocks.refreshUserProviderAccountQuota.mockResolvedValue({
      providerID: "openai",
      accountID: ACCOUNT_ID,
      sourceKind: "provider",
      sourceId: "usage",
      buckets: [],
      schemaVersion: 2,
      updatedAt: NOW,
    });
  });

  it("stamps the account provider rate-limit bucket before refreshing", async () => {
    seedProviderAccount();

    await expect(runAccountRefresh()).resolves.toMatchObject({
      providerID: "openai",
      accountID: ACCOUNT_ID,
    });

    expect(mocks.refreshUserProviderAccountQuota).toHaveBeenCalledWith(expect.anything(), ALICE_UID, ACCOUNT_ID);
    expect(mocks.store.get(`users/${ALICE_UID}/_rate_limits/refresh_openai`)).toHaveProperty("lastRefreshAt");
  });

  it("rejects hot account refreshes before calling quota providers", async () => {
    seedProviderAccount();
    seedDoc(mocks.store, `users/${ALICE_UID}/_rate_limits/refresh_openai`, {
      lastRefreshAt: { toMillis: () => Date.now() },
    });

    await expect(runAccountRefresh()).rejects.toThrow(/Rate limited/);
    expect(mocks.refreshUserProviderAccountQuota).not.toHaveBeenCalled();
  });
});
