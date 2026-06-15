/**
 * BOLA negative coverage — src/__tests__/bola/encryptedSearch.bola.test.ts
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
  "beginEncryptedSessionBlobUpload": [
    "beginEncryptedSessionBlobUpload rejects cross-user object access"
  ],
  "getEncryptedSessionBlobDownloadUrl": [
    "getEncryptedSessionBlobDownloadUrl rejects cross-user object access"
  ],
  "commitEncryptedSearchIndexBatch": [
    "commitEncryptedSearchIndexBatch rejects cross-user object access"
  ],
  "commitEncryptedProjectMemorySnapshot": [
    "commitEncryptedProjectMemorySnapshot rejects cross-user object access"
  ],
  "getEncryptedProjectMemorySnapshot": [
    "getEncryptedProjectMemorySnapshot rejects cross-user object access"
  ],
  "searchEncryptedConversationIndex": [
    "searchEncryptedConversationIndex rejects cross-user object access"
  ],
  "queryConversations": [
    "queryConversations rejects cross-user object access"
  ]
} as const;

describe("BOLA — encryptedSearch", () => {
  it("beginEncryptedSessionBlobUpload rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.beginEncryptedSessionBlobUpload;
    if (!exported) throw new Error("missing export beginEncryptedSessionBlobUpload");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("getEncryptedSessionBlobDownloadUrl rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.getEncryptedSessionBlobDownloadUrl;
    if (!exported) throw new Error("missing export getEncryptedSessionBlobDownloadUrl");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("commitEncryptedSearchIndexBatch rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.commitEncryptedSearchIndexBatch;
    if (!exported) throw new Error("missing export commitEncryptedSearchIndexBatch");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("commitEncryptedProjectMemorySnapshot rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.commitEncryptedProjectMemorySnapshot;
    if (!exported) throw new Error("missing export commitEncryptedProjectMemorySnapshot");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("getEncryptedProjectMemorySnapshot rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.getEncryptedProjectMemorySnapshot;
    if (!exported) throw new Error("missing export getEncryptedProjectMemorySnapshot");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("searchEncryptedConversationIndex rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.searchEncryptedConversationIndex;
    if (!exported) throw new Error("missing export searchEncryptedConversationIndex");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });

  it("queryConversations rejects cross-user object access", async () => {
    const mod = await import("../../callables/encryptedSearch.js");
    const exported = mod.queryConversations;
    if (!exported) throw new Error("missing export queryConversations");
    const run = callableRunner(exported);
    await expectCallableDenial(run, callableRequest(ALICE_UID, bolaCrossUserData()), "not-found");
  });
});
