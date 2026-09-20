/**
 * BOLA negative coverage — src/__tests__/bola/providerAccounts.bola.test.ts
 * Generated scaffold; implements cross-user denial at callable trust boundary.
 */

import { describe, it, vi, expect } from "vitest";
import { ALICE_UID, BOB_UID, callableRequest, callableRunner, pathKeyedFirestore, seedDoc, tier2CallableProof, snapshotTenantPaths, expectTenantPathsUnchanged } from "./callableBolaHarness.js";

import { providerAccountSecretRefPath } from "../../quota.js";

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
vi.mock("../../secrets.js", () => ({
  destroyCredential: vi.fn(async () => undefined),
  storeCredential: vi.fn(async () => "projects/test/secrets/x/versions/1"),
}));
export const BOLA_MANIFEST = {
  connectProviderAccount: ["connectProviderAccount rejects cross-user object access"],
  connectHostedQuotaAccount: ["connectHostedQuotaAccount rejects cross-user object access"],
  connectSelfHostedQuotaAccount: ["connectSelfHostedQuotaAccount rejects cross-user object access"],
  uploadProviderQuotaSnapshot: ["uploadProviderQuotaSnapshot rejects cross-user object access"],
  deleteHostedQuotaCredentials: ["deleteHostedQuotaCredentials rejects cross-user object access"],
  updateProviderAccount: ["updateProviderAccount rejects cross-user object access"],
  deleteProviderAccount: ["deleteProviderAccount rejects cross-user object access"],
  deleteProviderCredential: ["deleteProviderCredential rejects cross-user object access"],
  refreshProviderAccountQuota: ["refreshProviderAccountQuota rejects cross-user object access"],
} as const;

describe("BOLA — providerAccounts", () => {
  it("connectProviderAccount rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.connectProviderAccount;
    if (!exported) throw new Error("missing export connectProviderAccount");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "connectProviderAccount",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("connectHostedQuotaAccount rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.connectHostedQuotaAccount;
    if (!exported) throw new Error("missing export connectHostedQuotaAccount");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "connectHostedQuotaAccount",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("connectSelfHostedQuotaAccount rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.connectSelfHostedQuotaAccount;
    if (!exported) throw new Error("missing export connectSelfHostedQuotaAccount");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "connectSelfHostedQuotaAccount",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("uploadProviderQuotaSnapshot rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.uploadProviderQuotaSnapshot;
    if (!exported) throw new Error("missing export uploadProviderQuotaSnapshot");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "uploadProviderQuotaSnapshot",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });

  it("deleteHostedQuotaCredentials rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.deleteHostedQuotaCredentials;
    if (!exported) throw new Error("missing export deleteHostedQuotaCredentials");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "deleteHostedQuotaCredentials",
      run,
      expectedCode: "invalid-argument",
      expectedOutcome: "throws",
    });
  });

  it("updateProviderAccount rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.updateProviderAccount;
    if (!exported) throw new Error("missing export updateProviderAccount");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "updateProviderAccount",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });

  it("deleteProviderAccount rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.deleteProviderAccount;
    if (!exported) throw new Error("missing export deleteProviderAccount");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "deleteProviderAccount",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });

  it("deleteProviderCredential rejects cross-user object access", async () => {
    bolaStore.clear();
    const accountID = "openai_default";
    seedDoc(bolaStore, providerAccountSecretRefPath(BOB_UID, accountID), {
      secretVersionName: "projects/test/secrets/bob/versions/1",
    });
    seedDoc(bolaStore, `users/${BOB_UID}/provider_accounts/${accountID}`, {
      status: "connected",
      provider: "openai",
    });
    seedDoc(bolaStore, `users/${BOB_UID}/provider_connections/openai`, {
      status: "connected",
    });
    const bobBefore = snapshotTenantPaths(bolaStore, BOB_UID);

    const mod = await import("../../callables/providerAccounts.js");
    const run = callableRunner(mod.deleteProviderCredential);
    await run(callableRequest(ALICE_UID, { provider: "openai" }));

    // Catalog expectedOutcome: no-side-effect — credential delete is scoped to request.auth.uid only.
    expectTenantPathsUnchanged(bolaStore, bobBefore);
    expect(bolaStore.get(`users/${BOB_UID}/provider_accounts/${accountID}`)?.status).toBe("connected");
  });

  it("refreshProviderAccountQuota rejects cross-user object access", async () => {
    const mod = await import("../../callables/providerAccounts.js");
    const exported = mod.refreshProviderAccountQuota;
    if (!exported) throw new Error("missing export refreshProviderAccountQuota");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "refreshProviderAccountQuota",
      run,
      expectedCode: "not-found",
      expectedOutcome: "throws",
    });
  });
});
