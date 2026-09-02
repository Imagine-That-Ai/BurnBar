import { describe, expect, it } from "vitest";
import {
  expectCallableDenial,
  callableRequest,
  callableRunner,
  pathKeyedFirestore,
  tier2CallableProof,
} from "./callableBolaHarness.js";

describe("callableBolaHarness sanity", () => {
  it("expectCallableDenial fails when handler succeeds", async () => {
    const succeeding = { run: async () => ({ ok: true }) };
    let failed = false;
    try {
      await expectCallableDenial(callableRunner(succeeding), callableRequest("u", {}), "not-found");
    } catch (error) {
      failed = error instanceof Error && error.message.includes("expected callable to reject");
    }
    expect(failed).toBe(true);
  });

  it("expectCallableDenial rejects a mismatched code without fallback matching", async () => {
    const mismatched = {
      run: async () => {
        throw Object.assign(new Error("Resource not found"), { code: "permission-denied" });
      },
    };

    await expect(
      expectCallableDenial(
        callableRunner(mismatched),
        callableRequest("u", {}),
        "not-found",
      ),
    ).rejects.toMatchObject({ code: "permission-denied" });
  });

  it("tier2CallableProof fails successful calls when throws is expected", async () => {
    const store = new Map<string, Record<string, unknown>>();
    const succeeding = { run: async () => ({ ok: true }) };

    await expect(
      tier2CallableProof(store, {
        exportedName: "getEncryptedProjectMemorySnapshot",
        run: callableRunner(succeeding),
        expectedOutcome: "throws",
        expectedCode: "not-found",
      }),
    ).rejects.toThrow(/expected callable to reject/);
  });

  it("treats Firestore delete sentinels identifiable by constructor name as deletes", async () => {
    class DeleteTransform {}

    const store = new Map<string, Record<string, unknown>>([
      ["users/alice/documents/doc-1", { keep: true, remove: "legacy" }],
    ]);
    const db = pathKeyedFirestore(store);

    await db.doc("users/alice/documents/doc-1").update({ remove: new DeleteTransform() });

    expect(store.get("users/alice/documents/doc-1")).toEqual({ keep: true });
  });
});
