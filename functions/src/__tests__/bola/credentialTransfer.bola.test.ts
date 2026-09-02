/**
 * BOLA negative coverage — credential transfer v2 object ownership.
 */

import { describe, expect, it, vi } from "vitest";
import {
  ALICE_UID,
  BOB_UID,
  callableRequest,
  callableRunner,
  expectCallableDenial,
  pathKeyedFirestore,
  seedDoc,
} from "./callableBolaHarness.js";

import { Timestamp } from "firebase-admin/firestore";
import { sha256Hex } from "../../callables/shared.js";

const TRANSFER_ID = `ct_${"b".repeat(24)}`;
const CLAIM_ID = "11111111-1111-4111-8111-111111111111";
const store: Map<string, Record<string, unknown>> = vi.hoisted(() => new Map());

process.env.ENFORCE_APP_CHECK = "false";

vi.mock("../../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
}));
vi.mock("../../adminRuntime.js", () => ({
  db: pathKeyedFirestore(store),
}));

export const BOLA_MANIFEST = {
  createCredentialTransfer: ["createCredentialTransfer rejects cross-user object access"],
  consumeCredentialTransfer: ["consumeCredentialTransfer rejects cross-user object access"],
  completeCredentialTransfer: ["completeCredentialTransfer rejects cross-user object access"],
  cancelCredentialTransfer: ["cancelCredentialTransfer rejects cross-user object access"],
} as const;

function seedReadyTransfer(): void {
  seedDoc(store, `credential_transfers/${TRANSFER_ID}`, {
    ownerUid: BOB_UID,
    schemaVersion: 2,
    state: "ready",
    consumed: false,
    expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
    payload: `v2.${"s".repeat(22)}.${"i".repeat(16)}.${"c".repeat(32)}`,
  });
}

function seedClaimedTransfer(): void {
  seedDoc(store, `credential_transfers/${TRANSFER_ID}`, {
    ownerUid: BOB_UID,
    schemaVersion: 2,
    state: "claimed",
    consumed: false,
    expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
    claimedByUid: BOB_UID,
    claimExpiresAt: Timestamp.fromMillis(Date.now() + 60_000),
    claimIdHash: sha256Hex(`${BOB_UID}:${TRANSFER_ID}:${CLAIM_ID}`),
    payload: `v2.${"s".repeat(22)}.${"i".repeat(16)}.${"c".repeat(32)}`,
  });
}

describe("BOLA — credentialTransfer", () => {
  it("createCredentialTransfer rejects cross-user object access", async () => {
    store.clear();
    seedReadyTransfer();
    const before = store.get(`credential_transfers/${TRANSFER_ID}`);

    const mod = await import("../../callables/credentialTransfer.js");
    const run = callableRunner(mod.createCredentialTransfer);
    await expectCallableDenial(
      run,
      callableRequest(ALICE_UID, {
        transferId: TRANSFER_ID,
        payload: `v2.${"s".repeat(22)}.${"i".repeat(16)}.${"c".repeat(32)}`,
      }),
      "already-exists",
    );
    expect(store.get(`credential_transfers/${TRANSFER_ID}`)).toEqual(before);
  });

  it("consumeCredentialTransfer rejects cross-user object access", async () => {
    store.clear();
    seedReadyTransfer();

    const mod = await import("../../callables/credentialTransfer.js");
    const run = callableRunner(mod.consumeCredentialTransfer);
    await expectCallableDenial(run, callableRequest(ALICE_UID, { transferId: TRANSFER_ID }), "permission-denied");
  });

  it("completeCredentialTransfer rejects cross-user object access", async () => {
    store.clear();
    seedClaimedTransfer();

    const mod = await import("../../callables/credentialTransfer.js");
    const run = callableRunner(mod.completeCredentialTransfer);
    await expectCallableDenial(
      run,
      callableRequest(ALICE_UID, { transferId: TRANSFER_ID, claimId: CLAIM_ID }),
      "permission-denied",
    );
  });

  it("cancelCredentialTransfer rejects cross-user object access", async () => {
    store.clear();
    seedClaimedTransfer();

    const mod = await import("../../callables/credentialTransfer.js");
    const run = callableRunner(mod.cancelCredentialTransfer);
    await expectCallableDenial(
      run,
      callableRequest(ALICE_UID, { transferId: TRANSFER_ID, claimId: CLAIM_ID }),
      "permission-denied",
    );
  });

  it("consumeCredentialTransfer rejects legacy human codes before lookup", async () => {
    store.clear();
    seedDoc(store, "credential_transfers/ABCDEFGHJKMN", {
      ownerUid: BOB_UID,
      consumed: false,
      payload: "v1.test",
    });

    const mod = await import("../../callables/credentialTransfer.js");
    const run = callableRunner(mod.consumeCredentialTransfer);
    await expectCallableDenial(
      run,
      callableRequest(ALICE_UID, { transferId: "ABCDEFGHJKMN" }),
      "invalid-argument",
    );
  });
});
