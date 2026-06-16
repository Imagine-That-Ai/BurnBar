/**
 * FINDING-006 / B.4 — Account erasure writes a durable pre-delete audit intent
 * and a best-effort post-delete completion record. The intent is fail-closed:
 * if it cannot be persisted, no data is destroyed.
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

function fakeDb() {
  return {
    collection: () => ({
      where: () => ({ get: async () => ({ docs: [], empty: true }) }),
      listDocuments: async () => [],
    }),
    doc: () => ({
      listCollections: async () => [],
      collection: () => ({
        listDocuments: async () => [],
      }),
    }),
    batch: () => ({
      delete: vi.fn(),
      commit: vi.fn(async () => undefined),
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
    appendAuditEvent: AccountDeletionAuditAppender;
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
      appendAuditEvent: overrides.appendAuditEvent ?? appendAuditEvent,
    },
  };
}

describe("eraseUserAccount — durable deletion audit", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("persists a pre-delete intent before destroying data", async () => {
    await eraseUserAccount(fakeDb(), "u1", baseOptions());
    expect(appendAuditEventRequired).toHaveBeenCalledTimes(1);
    expect(appendAuditEventRequired).toHaveBeenCalledWith(
      "u1",
      expect.objectContaining({
        actor: "user:ios",
        action: "account.delete.intent",
        domain: "account",
      }),
    );
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

  it("appends a best-effort completion record after successful deletion", async () => {
    await eraseUserAccount(fakeDb(), "u1", baseOptions());
    expect(appendAuditEvent).toHaveBeenCalledTimes(1);
    expect(appendAuditEvent).toHaveBeenCalledWith(
      "u1",
      expect.objectContaining({
        actor: "user:ios",
        action: "account.delete.complete",
        domain: "account",
      }),
    );
  });

  it("still succeeds when the best-effort completion record fails", async () => {
    const failingCompletion = vi.fn(async () => {
      throw new Error("completion audit unavailable");
    });

    const result = await eraseUserAccount(
      fakeDb(),
      "u1",
      baseOptions({ appendAuditEvent: failingCompletion }),
    );

    expect(result.deletedAuthUser).toBe(true);
    expect(appendAuditEventRequired).toHaveBeenCalledTimes(1);
    expect(failingCompletion).toHaveBeenCalledTimes(1);
  });

  it("still records completion when the auth user is already missing", async () => {
    const userNotFound = Object.assign(new Error("No such user"), { code: "auth/user-not-found" });

    const result = await eraseUserAccount(
      fakeDb(),
      "u1",
      baseOptions({
        deleteAuthUser: async () => {
          throw userNotFound;
        },
      }),
    );

    expect(result.deletedAuthUser).toBe(false);
    expect(result.authUserAlreadyMissing).toBe(true);
    expect(appendAuditEvent).toHaveBeenCalledTimes(1);
  });
});
