/**
 * BOLA negative coverage — src/__tests__/bola/encryptedSearch.bola.test.ts
 * Generated scaffold; implements cross-user denial at callable trust boundary.
 */

import { describe, expect, it, vi } from "vitest";
import {
  ALICE_UID,
  BOB_UID,
  callableRequest,
  callableRunner,
  expectTenantPathsUnchanged,
  pathKeyedFirestore,
  snapshotTenantPaths,
  tier2CallableProof,
} from "./callableBolaHarness.js";
import { seedBolaVictimTenant } from "./bolaVictimSeeds.generated.js";

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
  beginEncryptedSessionBlobUpload: ["beginEncryptedSessionBlobUpload rejects cross-user object access"],
  getEncryptedSessionBlobDownloadUrl: ["getEncryptedSessionBlobDownloadUrl rejects cross-user object access"],
  commitEncryptedSearchIndexBatch: ["commitEncryptedSearchIndexBatch rejects cross-user object access"],
  commitEncryptedProjectMemorySnapshot: ["commitEncryptedProjectMemorySnapshot rejects cross-user object access"],
  deleteEncryptedProjectMemorySnapshot: ["deleteEncryptedProjectMemorySnapshot leaves cross-user project memory untouched"],
  getEncryptedProjectMemorySnapshot: ["getEncryptedProjectMemorySnapshot rejects cross-user object access"],
  searchEncryptedConversationIndex: ["searchEncryptedConversationIndex rejects cross-user object access"],
  queryConversations: ["queryConversations rejects cross-user object access"],
} as const;

describe("BOLA — encryptedSearch", () => {
  it("beginEncryptedSessionBlobUpload rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.beginEncryptedSessionBlobUpload;
    if (!exported) throw new Error("missing export beginEncryptedSessionBlobUpload");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "beginEncryptedSessionBlobUpload",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("getEncryptedSessionBlobDownloadUrl rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.getEncryptedSessionBlobDownloadUrl;
    if (!exported) throw new Error("missing export getEncryptedSessionBlobDownloadUrl");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "getEncryptedSessionBlobDownloadUrl",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("commitEncryptedSearchIndexBatch rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.commitEncryptedSearchIndexBatch;
    if (!exported) throw new Error("missing export commitEncryptedSearchIndexBatch");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "commitEncryptedSearchIndexBatch",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("commitEncryptedProjectMemorySnapshot rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.commitEncryptedProjectMemorySnapshot;
    if (!exported) throw new Error("missing export commitEncryptedProjectMemorySnapshot");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "commitEncryptedProjectMemorySnapshot",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("getEncryptedProjectMemorySnapshot rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.getEncryptedProjectMemorySnapshot;
    if (!exported) throw new Error("missing export getEncryptedProjectMemorySnapshot");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "getEncryptedProjectMemorySnapshot",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("deleteEncryptedProjectMemorySnapshot leaves cross-user project memory untouched", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.deleteEncryptedProjectMemorySnapshot;
    if (!exported) throw new Error("missing export deleteEncryptedProjectMemorySnapshot");
    const run = callableRunner(exported);

    bolaStore.clear();
    seedBolaVictimTenant(bolaStore, "deleteEncryptedProjectMemorySnapshot");
    bolaStore.set(`users/${ALICE_UID}/entitlements/burnbar_pro`, {
      active: true,
      productID: "com.openburnbar.pro.monthly",
      expiresAt: "2999-01-01T00:00:00.000Z",
    });

    const victimBefore = snapshotTenantPaths(bolaStore, BOB_UID);
    await run(callableRequest(ALICE_UID, { docID: "bob-doc" }));

    expectTenantPathsUnchanged(bolaStore, victimBefore);
    expect(bolaStore.has(`users/${BOB_UID}/project_memory_snapshots/bob-doc`)).toBe(true);
    expect(bolaStore.has(`users/${ALICE_UID}/project_memory_tombstones/bob-doc`)).toBe(true);
  });

  it("searchEncryptedConversationIndex rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.searchEncryptedConversationIndex;
    if (!exported) throw new Error("missing export searchEncryptedConversationIndex");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "searchEncryptedConversationIndex",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });

  it("queryConversations rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.queryConversations;
    if (!exported) throw new Error("missing export queryConversations");
    const run = callableRunner(exported);

    await tier2CallableProof(bolaStore, {
      exportedName: "queryConversations",
      run,
      expectedCode: "permission-denied",
      expectedOutcome: "throws",
    });
  });
});
