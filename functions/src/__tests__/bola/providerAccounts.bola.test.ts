/**
 * BOLA negative coverage — src/__tests__/bola/providerAccounts.bola.test.ts
 * Generated scaffold; implements cross-user denial at callable trust boundary.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ALICE_UID, BOB_UID, callableRequest, callableRunner, expectCallableDenial, bolaCrossUserData, pathKeyedFirestore } from "./callableBolaHarness.js";

process.env.ENFORCE_APP_CHECK = "false";

const bolaStore = vi.hoisted(() => new Map());
vi.mock("../../adminRuntime.js", () => ({ db: pathKeyedFirestore(bolaStore) }));
vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return {
    ...actual,
    getFirestore: () => pathKeyedFirestore(bolaStore),
  };
});

vi.mock("../../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
  assertAppCheck: vi.fn(),
}));
vi.mock("../../callables/highRiskOwnerAction.js", () => ({
  enforceHighRiskOwnerAction: vi.fn(async () => undefined),
}));
vi.mock("../../appCheckAttestation.js", async () => {
  const actual = await vi.importActual<typeof import("../../appCheckAttestation.js")>("../../appCheckAttestation.js");
  return {
    ...actual,
    enforceHighRiskComputerUseCallableWithNonce: vi.fn(async () => ({ nonceConsumed: true })),
  };
});
export const BOLA_MANIFEST = {
  "connectProviderAccount": [
    "connectProviderAccount rejects cross-user object access"
  ],
  "connectHostedQuotaAccount": [
    "connectHostedQuotaAccount rejects cross-user object access"
  ],
  "connectSelfHostedQuotaAccount": [
    "connectSelfHostedQuotaAccount rejects cross-user object access"
  ],
  "uploadProviderQuotaSnapshot": [
    "uploadProviderQuotaSnapshot rejects cross-user object access"
  ],
  "deleteHostedQuotaCredentials": [
    "deleteHostedQuotaCredentials rejects cross-user object access"
  ],
  "updateProviderAccount": [
    "updateProviderAccount rejects cross-user object access"
  ],
  "deleteProviderAccount": [
    "deleteProviderAccount rejects cross-user object access"
  ],
  "deleteProviderCredential": [
    "deleteProviderCredential rejects cross-user object access"
  ],
  "refreshProviderAccountQuota": [
    "refreshProviderAccountQuota rejects cross-user object access"
  ]
} as const;

describe("BOLA — providerAccounts", () => {
  it("connectProviderAccount rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.connectProviderAccount;
    if (!exported) throw new Error("missing export connectProviderAccount");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("connectHostedQuotaAccount rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.connectHostedQuotaAccount;
    if (!exported) throw new Error("missing export connectHostedQuotaAccount");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("connectSelfHostedQuotaAccount rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.connectSelfHostedQuotaAccount;
    if (!exported) throw new Error("missing export connectSelfHostedQuotaAccount");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("uploadProviderQuotaSnapshot rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.uploadProviderQuotaSnapshot;
    if (!exported) throw new Error("missing export uploadProviderQuotaSnapshot");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("deleteHostedQuotaCredentials rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.deleteHostedQuotaCredentials;
    if (!exported) throw new Error("missing export deleteHostedQuotaCredentials");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("updateProviderAccount rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.updateProviderAccount;
    if (!exported) throw new Error("missing export updateProviderAccount");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("deleteProviderAccount rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.deleteProviderAccount;
    if (!exported) throw new Error("missing export deleteProviderAccount");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("deleteProviderCredential rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.deleteProviderCredential;
    if (!exported) throw new Error("missing export deleteProviderCredential");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("refreshProviderAccountQuota rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.refreshProviderAccountQuota;
    if (!exported) throw new Error("missing export refreshProviderAccountQuota");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });
});
