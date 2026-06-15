/**
 * BOLA negative coverage — consumeCredentialTransfer cross-tenant denial.
 */
import { Timestamp } from "firebase-admin/firestore";
import { describe, it, vi } from "vitest";

import { ALICE_UID, BOB_UID, callableRequest, callableRunner, expectCallableDenial, pathKeyedFirestore, seedDoc } from "./callableBolaHarness.js";

const TRANSFER_CODE = "ABCDEFGHJKMN";
const store: Map<string, Record<string, unknown>> = vi.hoisted(() => new Map());

process.env.ENFORCE_APP_CHECK = "false";

vi.mock("../../auth.js", () => ({
  enforceAuthAndAppCheck: vi.fn(),
}));
vi.mock("../../adminRuntime.js", () => ({
  db: pathKeyedFirestore(store),
}));

export const BOLA_MANIFEST = {
  consumeCredentialTransfer: ["consumeCredentialTransfer rejects cross-user object access"],
} as const;

describe("BOLA — credentialTransfer", () => {
  it("consumeCredentialTransfer rejects cross-user object access", async () => {
    store.clear();
    seedDoc(store, `credential_transfers/${TRANSFER_CODE}`, {
      ownerUid: BOB_UID,
      consumed: false,
      expiresAt: Timestamp.fromMillis(Date.now() + 60_000),
      payload: "v1.a.b.c",
    });

    const mod = await import("../../callables/credentialTransfer.js");
    const run = callableRunner(mod.consumeCredentialTransfer);
    await expectCallableDenial(run, callableRequest(ALICE_UID, { code: TRANSFER_CODE }), "permission-denied");
  });
});
