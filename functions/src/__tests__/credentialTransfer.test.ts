import { beforeEach, describe, expect, it, vi } from "vitest";
import { Timestamp } from "firebase-admin/firestore";

import { ALICE_UID, callableRequest, callableRunner, pathKeyedFirestore, seedDoc } from "./bola/callableBolaHarness.js";

const store: Map<string, Record<string, unknown>> = vi.hoisted(() => new Map());

process.env.ENFORCE_APP_CHECK = "false";

vi.mock("../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
}));
vi.mock("../adminRuntime.js", () => ({
  db: pathKeyedFirestore(store),
}));

const TRANSFER_ID = `ct_${"a".repeat(24)}`;
const OTHER_TRANSFER_ID = `ct_${"b".repeat(24)}`;
const PAYLOAD = `v2.${"s".repeat(22)}.${"i".repeat(16)}.${"c".repeat(32)}`;

function path(id = TRANSFER_ID): string {
  return `credential_transfers/${id}`;
}

async function moduleUnderTest() {
  return import("../callables/credentialTransfer.js");
}

async function runCallable(exported: "createCredentialTransfer" | "consumeCredentialTransfer" | "completeCredentialTransfer" | "cancelCredentialTransfer", data: Record<string, unknown>, uid = ALICE_UID) {
  const mod = await moduleUnderTest();
  return callableRunner(mod[exported])(callableRequest(uid, data));
}

function stringField(value: unknown, key: string): string {
  const field = value && typeof value === "object" ? Reflect.get(value, key) : undefined;
  expect(typeof field).toBe("string");
  return field;
}

async function expectHttpsCode(promise: Promise<unknown>, code: string): Promise<void> {
  await expect(promise).rejects.toMatchObject({ code });
}

describe("credential transfer v2 callables", () => {
  beforeEach(() => {
    store.clear();
  });

  it("validates opaque transfer ids and rejects legacy/full-token lookup inputs", async () => {
    const { __testing__ } = await moduleUnderTest();
    expect(__testing__.normalizeCredentialTransferId(TRANSFER_ID)).toBe(TRANSFER_ID);

    for (const value of [
      "ABCDEFGHJKM2",
      "abcd-efgh-jkm2",
      `obbct_v2.${TRANSFER_ID}.ABCD-EFGH-JKMN-PQRS-TUVW-XYZ2-34`,
      "../ct_bad",
      "ct_short",
    ]) {
      expect(() => __testing__.normalizeCredentialTransferId(value)).toThrow();
    }
  });

  it("creates ciphertext-only v2 documents and never persists a secret or legacy lookup", async () => {
    const result = await runCallable("createCredentialTransfer", {
      transferId: TRANSFER_ID,
      payload: PAYLOAD,
    });

    expect(result).toEqual({ ok: true, transferId: TRANSFER_ID });
    const doc = store.get(path());
    expect(doc).toMatchObject({
      ownerUid: ALICE_UID,
      schemaVersion: 2,
      payload: PAYLOAD,
      state: "ready",
      consumed: false,
    });
    expect(JSON.stringify(doc)).not.toContain("ABCD-EFGH-JKMN");
    expect(JSON.stringify(doc)).not.toContain("secret");
    expect(doc).not.toHaveProperty("code");
    expect(doc).not.toHaveProperty("codeHash");
  });

  it("rejects v1 payloads, legacy request fields, and full tokens before lookup", async () => {
    await expectHttpsCode(
      runCallable("createCredentialTransfer", {
        transferId: TRANSFER_ID,
        payload: "v1.a.b.c",
      }),
      "invalid-argument",
    );
    await expectHttpsCode(
      runCallable("createCredentialTransfer", {
        transferId: TRANSFER_ID,
        payload: PAYLOAD,
        code: "ABCDEFGHJKM2",
      }),
      "invalid-argument",
    );
    await expectHttpsCode(
      runCallable("consumeCredentialTransfer", {
        transferId: `obbct_v2.${TRANSFER_ID}.ABCD-EFGH-JKMN-PQRS-TUVW-XYZ2-34`,
      }),
      "invalid-argument",
    );
    expect(store.size).toBe(0);
  });

  it("claims, completes, and idempotently re-completes after local decrypt succeeds", async () => {
    await runCallable("createCredentialTransfer", { transferId: TRANSFER_ID, payload: PAYLOAD });

    const claim = await runCallable("consumeCredentialTransfer", { transferId: TRANSFER_ID });
    const payload = stringField(claim, "payload");
    const claimId = stringField(claim, "claimId");
    expect(payload).toBe(PAYLOAD);
    expect(claimId).toMatch(/^[0-9a-f-]{36}$/u);
    const claimed = store.get(path());
    expect(claimed).toMatchObject({
      state: "claimed",
      claimedByUid: ALICE_UID,
    });
    expect(claimed?.claimIdHash).not.toBe(claimId);

    await expect(runCallable("completeCredentialTransfer", { transferId: TRANSFER_ID, claimId })).resolves.toEqual({
      ok: true,
      state: "consumed",
    });
    await expect(runCallable("completeCredentialTransfer", { transferId: TRANSFER_ID, claimId })).resolves.toEqual({
      ok: true,
      state: "consumed",
    });
    expect(store.get(path())).toMatchObject({
      state: "consumed",
      consumed: true,
    });
    await expectHttpsCode(runCallable("consumeCredentialTransfer", { transferId: TRANSFER_ID }), "failed-precondition");
  });

  it("rejects replay with a mismatched claim", async () => {
    await runCallable("createCredentialTransfer", { transferId: TRANSFER_ID, payload: PAYLOAD });
    await runCallable("consumeCredentialTransfer", { transferId: TRANSFER_ID });

    await expectHttpsCode(
      runCallable("completeCredentialTransfer", {
        transferId: TRANSFER_ID,
        claimId: "00000000-0000-4000-8000-000000000000",
      }),
      "permission-denied",
    );
    expect(store.get(path())).toMatchObject({ state: "claimed", consumed: false });
  });

  it("allows expired claims to be overwritten by a fresh claim", async () => {
    seedDoc(store, path(), {
      ownerUid: ALICE_UID,
      schemaVersion: 2,
      state: "claimed",
      consumed: false,
      payload: PAYLOAD,
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      claimedByUid: ALICE_UID,
      claimExpiresAt: Timestamp.fromMillis(Date.now() - 1_000),
      claimIdHash: "old-claim",
    });

    const claim = await runCallable("consumeCredentialTransfer", { transferId: TRANSFER_ID });
    const claimId = stringField(claim, "claimId");
    expect(claimId).toMatch(/^[0-9a-f-]{36}$/u);
    expect(store.get(path())?.claimIdHash).not.toBe("old-claim");
    expect(store.get(path())).toMatchObject({ state: "claimed", claimedByUid: ALICE_UID });
  });

  it("cancel releases a failed decrypt claim so the transfer can be retried", async () => {
    await runCallable("createCredentialTransfer", { transferId: OTHER_TRANSFER_ID, payload: PAYLOAD });
    const firstClaim = await runCallable("consumeCredentialTransfer", { transferId: OTHER_TRANSFER_ID });
    const firstClaimId = stringField(firstClaim, "claimId");

    await expect(
      runCallable("cancelCredentialTransfer", {
        transferId: OTHER_TRANSFER_ID,
        claimId: firstClaimId,
      }),
    ).resolves.toEqual({ ok: true, state: "ready" });
    expect(store.get(path(OTHER_TRANSFER_ID))).toMatchObject({ state: "ready", consumed: false });

    const secondClaim = await runCallable("consumeCredentialTransfer", { transferId: OTHER_TRANSFER_ID });
    expect(stringField(secondClaim, "claimId")).not.toBe(firstClaimId);
  });
});
