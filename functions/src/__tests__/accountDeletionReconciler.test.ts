import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it, vi } from "vitest";

vi.mock("firebase-functions/v2/scheduler", () => ({ onSchedule: (_options: unknown, handler: unknown) => handler }));
vi.mock("../adminRuntime.js", () => ({ db: {}, auth: {} }));
vi.mock("../accountDeletion.js", () => ({ eraseUserAccount: vi.fn(), isAccountErasureResumable: vi.fn() }));
vi.mock("../logging.js", () => ({ logError: vi.fn(), logInfo: vi.fn() }));
vi.mock("../runtimeOptions.js", () => ({ FUNCTIONS_REGION: "us-central1" }));
vi.mock("../secrets.js", () => ({ destroyCredential: vi.fn() }));

import { reconcilePendingAccountErasures } from "../accountDeletionReconciler.js";

function tombstone(id: string, attemptCount = 0) {
  const patches: Record<string, unknown>[] = [];
  return {
    document: {
      id,
      get: (field: string) => (field === "reconciliationAttemptCount" ? attemptCount : undefined),
      ref: {
        set: async (data: Record<string, unknown>) => {
          patches.push(data);
        },
      },
    },
    patches,
  };
}

describe("account erasure reconciler", () => {
  const now = new Date("2026-07-10T12:00:00.000Z");

  it("quarantines a poison tombstone without removing the account barrier", async () => {
    const poison = tombstone("poison");
    const results = await reconcilePendingAccountErasures([poison.document], {
      isResumable: async () => false,
      erase: async () => undefined,
      now: () => now,
    });

    expect(results).toEqual([{ uid: "poison", status: "quarantined", errorCode: "missing_resumable_receipt" }]);
    expect(poison.patches).toEqual([
      expect.objectContaining({
        pending: false,
        reconciliationStatus: "quarantined",
        updatedAt: now.toISOString(),
      }),
    ]);
  });

  it("moves a transient failure to the back and increments its attempt count", async () => {
    const retry = tombstone("retry", 2);
    const results = await reconcilePendingAccountErasures([retry.document], {
      isResumable: async () => true,
      erase: async () => {
        throw new Error("temporary outage");
      },
      now: () => now,
    });

    expect(results).toEqual([{ uid: "retry", status: "failed", errorCode: "Error" }]);
    expect(retry.patches).toEqual([
      expect.objectContaining({
        reconciliationStatus: "retry_pending",
        reconciliationAttemptCount: 3,
        updatedAt: now.toISOString(),
      }),
    ]);
  });

  it("leaves successful completion to the canonical erasure transaction", async () => {
    const success = tombstone("success");
    const erase = vi.fn(async () => undefined);
    const results = await reconcilePendingAccountErasures([success.document], {
      isResumable: async () => true,
      erase,
      now: () => now,
    });

    expect(results).toEqual([{ uid: "success", status: "completed" }]);
    expect(erase).toHaveBeenCalledWith("success");
    expect(success.patches).toEqual([]);
  });

  it("declares the oldest-first pending tombstone index", () => {
    const manifest: {
      indexes: Array<{
        collectionGroup: string;
        queryScope: string;
        fields: Array<{ fieldPath: string; order: string }>;
      }>;
    } = JSON.parse(readFileSync(resolve(process.cwd(), "../firestore.indexes.json"), "utf8"));
    expect(manifest.indexes).toContainEqual({
      collectionGroup: "account_erasure_tombstones",
      queryScope: "COLLECTION",
      fields: [
        { fieldPath: "pending", order: "ASCENDING" },
        { fieldPath: "updatedAt", order: "ASCENDING" },
      ],
    });
  });
});
