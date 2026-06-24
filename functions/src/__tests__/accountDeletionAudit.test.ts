/**
 * Account erasure writes a durable pre-delete retention record outside the
 * user subtree. The intent is fail-closed: if it cannot be persisted, no data
 * is destroyed.
 */
import { describe, expect, it, vi, beforeEach } from "vitest";

// Silence firebase-functions logger output during the test run.
vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

vi.mock("../logging.js", () => ({
  logWarn: vi.fn(),
  logError: vi.fn(),
  logInfo: vi.fn(),
}));

vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({
    bucket: () => ({
      deleteFiles: vi.fn(async () => undefined),
      getFiles: async () => [[]],
    }),
  }),
}));

const { appendAuditEventRequired, appendAuditEvent } = vi.hoisted(() => ({
  appendAuditEventRequired: vi.fn(async () => ({ seq: 0, hash: "intent" })),
  appendAuditEvent: vi.fn(async () => ({ seq: 1, hash: "complete" })),
}));
vi.mock("../callables/auditLog.js", () => ({
  appendAuditEventRequired,
  appendAuditEvent,
  auditActorLabel: () => "user:ios",
  AUDIT_ACTIONS: {
    accountDeleteIntent: "account.delete.intent",
    accountDeleteComplete: "account.delete.complete",
  },
}));

import { eraseUserAccount } from "../accountDeletion.js";

type Operation =
  | { op: "set"; path: string; data: Record<string, unknown>; options?: { merge?: boolean } }
  | { op: "delete"; path: string }
  | { op: "commit"; path: string };

function fakeDb({
  operations = [],
  failErasureAuditSet = false,
}: {
  operations?: Operation[];
  failErasureAuditSet?: boolean;
} = {}) {
  const makeDoc = (path: string) => ({
    path,
    set: vi.fn(async (data: Record<string, unknown>, options?: { merge?: boolean }) => {
      if (failErasureAuditSet && path.startsWith("account_erasure_audit/")) {
        throw new Error("durable erasure audit unavailable");
      }
      operations.push({ op: "set", path, data, options });
    }),
    listCollections: async () => [],
    collection: () => ({
      listDocuments: async () => [],
    }),
  });
  return {
    collection: () => ({
      where: () => ({ get: async () => ({ docs: [], empty: true }) }),
      listDocuments: async () => [],
    }),
    doc: (path: string) => makeDoc(path),
    batch: () => ({
      delete: vi.fn((ref: { path?: string }) => {
        operations.push({ op: "delete", path: ref.path ?? "" });
      }),
      commit: vi.fn(async () => {
        operations.push({ op: "commit", path: "batch" });
      }),
    }),
  };
}

type AccountDeletionAuditAppender = (
  uid: string,
  event: { actor: string; action: string; domain: string },
) => Promise<unknown>;

function baseOptions(
  overrides: Partial<{
    deleteAuthUser: () => Promise<void>;
    appendAuditEventRequired: AccountDeletionAuditAppender;
  }> = {},
) {
  return {
    deleteStorageObjects: async () => {},
    destroyCredential: async () => {},
    deleteAuthUser: overrides.deleteAuthUser ?? (async () => {}),
    audit: {
      actor: "user:ios",
      domain: "account",
      appendAuditEventRequired: overrides.appendAuditEventRequired ?? appendAuditEventRequired,
    },
  };
}

describe("eraseUserAccount — durable deletion audit", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("persists a pre-delete intent before destroying data", async () => {
    const operations: Operation[] = [];

    await eraseUserAccount(fakeDb({ operations }), "u1", baseOptions());

    expect(appendAuditEventRequired).toHaveBeenCalledTimes(1);
    expect(appendAuditEventRequired).toHaveBeenCalledWith(
      "u1",
      expect.objectContaining({
        actor: "user:ios",
        action: "account.delete.intent",
        domain: "account",
      }),
    );

    const erasureAuditIntentIndex = operations.findIndex(
      (operation) =>
        operation.op === "set" &&
        operation.path.startsWith("account_erasure_audit/") &&
        operation.data.status === "intent_recorded",
    );
    const userTreeDeleteIndex = operations.findIndex(
      (operation) => operation.op === "delete" && operation.path === "users/u1",
    );

    expect(erasureAuditIntentIndex).toBeGreaterThanOrEqual(0);
    expect(userTreeDeleteIndex).toBeGreaterThanOrEqual(0);
    expect(erasureAuditIntentIndex).toBeLessThan(userTreeDeleteIndex);
  });

  it("fails closed and destroys nothing when the intent cannot be persisted", async () => {
    const deleteAuthUser = vi.fn(async () => {});
    const failingIntent = vi.fn(async () => {
      throw new Error("audit intent unavailable");
    });

    await expect(
      eraseUserAccount(fakeDb(), "u1", baseOptions({ deleteAuthUser, appendAuditEventRequired: failingIntent })),
    ).rejects.toThrow(/audit intent unavailable/);

    expect(failingIntent).toHaveBeenCalledTimes(1);
    expect(deleteAuthUser).not.toHaveBeenCalled();
    expect(appendAuditEvent).not.toHaveBeenCalled();
  });

  it("fails closed and destroys nothing when the durable retention record cannot be persisted", async () => {
    const operations: Operation[] = [];
    const deleteAuthUser = vi.fn(async () => {});

    await expect(
      eraseUserAccount(fakeDb({ operations, failErasureAuditSet: true }), "u1", baseOptions({ deleteAuthUser })),
    ).rejects.toThrow(/durable erasure audit unavailable/);

    expect(appendAuditEventRequired).toHaveBeenCalledTimes(1);
    expect(deleteAuthUser).not.toHaveBeenCalled();
    expect(appendAuditEvent).not.toHaveBeenCalled();
    expect(operations.find((operation) => operation.op === "delete")).toBeUndefined();
  });

  it("updates the durable retention record after successful deletion without recreating a user audit entry", async () => {
    const operations: Operation[] = [];

    const result = await eraseUserAccount(fakeDb({ operations }), "u1", baseOptions());

    const statusUpdates = operations
      .filter((operation): operation is Extract<Operation, { op: "set" }> => operation.op === "set")
      .filter((operation) => operation.path.startsWith("account_erasure_audit/"))
      .map((operation) => operation.data.status);

    expect(result.deletedAuthUser).toBe(true);
    expect(statusUpdates).toEqual(["intent_recorded", "cloud_data_deleted", "account_deleted"]);
    expect(appendAuditEvent).not.toHaveBeenCalled();
    expect(
      operations.find(
        (operation) =>
          operation.op === "set" &&
          operation.path.startsWith("users/u1/unified_audit_log/") &&
          operation.data.action === "account.delete.complete",
      ),
    ).toBeUndefined();
  });

  it("does not store the raw uid in the durable retention record", async () => {
    const operations: Operation[] = [];

    await eraseUserAccount(fakeDb({ operations }), "u1", baseOptions());

    const erasureAuditWrites = operations.filter(
      (operation): operation is Extract<Operation, { op: "set" }> =>
        operation.op === "set" && operation.path.startsWith("account_erasure_audit/"),
    );

    expect(erasureAuditWrites.length).toBeGreaterThan(0);
    expect(erasureAuditWrites.some((write) => typeof write.data.uidHash === "string")).toBe(true);
    for (const write of erasureAuditWrites) {
      expect(write.path).not.toContain("u1");
      expect(JSON.stringify(write.data)).not.toContain("u1");
      if (typeof write.data.uidHash === "string") {
        expect(write.data.uidHash).toMatch(/^[a-f0-9]{64}$/u);
      }
    }
  });

  it("still records durable completion when the auth user is already missing", async () => {
    const userNotFound = Object.assign(new Error("No such user"), { code: "auth/user-not-found" });
    const operations: Operation[] = [];

    const result = await eraseUserAccount(
      fakeDb({ operations }),
      "u1",
      baseOptions({
        deleteAuthUser: async () => {
          throw userNotFound;
        },
      }),
    );

    expect(result.deletedAuthUser).toBe(false);
    expect(result.authUserAlreadyMissing).toBe(true);
    expect(
      operations.find(
        (operation) =>
          operation.op === "set" &&
          operation.path.startsWith("account_erasure_audit/") &&
          operation.data.status === "auth_user_already_missing",
      ),
    ).toBeDefined();
    expect(appendAuditEvent).not.toHaveBeenCalled();
  });
});
