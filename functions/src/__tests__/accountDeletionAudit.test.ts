/**
 * Account erasure writes a durable pre-delete retention record outside the
 * user subtree. The intent is fail-closed: if it cannot be persisted, no data
 * is destroyed.
 */
import { describe, expect, it, vi, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

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

const { deleteStorageFiles, listStorageFiles } = vi.hoisted(() => ({
  deleteStorageFiles: vi.fn(async () => undefined),
  listStorageFiles: vi.fn<() => Promise<[unknown[]]>>(async () => [[]]),
}));
vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({
    bucket: () => ({
      deleteFiles: deleteStorageFiles,
      getFiles: listStorageFiles,
    }),
  }),
}));

const { appendAuditEventRequired, appendAuditEvent, computeAuditHash } = vi.hoisted(() => {
  const hashFor = (core: Record<string, unknown>) => {
    const payload = JSON.stringify({
      seq: core.seq,
      ts: core.ts,
      actor: core.actor,
      action: core.action,
      domain: core.domain,
      prevHash: core.prevHash,
    });
    let value = 0x811c9dc5;
    for (const character of `${String(core.prevHash ?? "")}${payload}`) {
      value = Math.imul(value ^ character.charCodeAt(0), 0x01000193) >>> 0;
    }
    return value.toString(16).padStart(8, "0").repeat(8);
  };
  const intent = {
    seq: 0,
    ts: "2026-07-10T00:00:00.000Z",
    actor: "user:ios",
    action: "account.delete.intent",
    domain: "account",
    prevHash: "",
  };
  return {
    computeAuditHash: vi.fn(hashFor),
    appendAuditEventRequired: vi.fn(async () => ({
      ...intent,
      hash: hashFor(intent),
    })),
    appendAuditEvent: vi.fn(),
  };
});
vi.mock("../callables/auditLog.js", () => ({
  appendAuditEventRequired,
  appendAuditEvent,
  computeAuditHash,
  auditActorLabel: () => "user:ios",
  AUDIT_ACTIONS: {
    accountDeleteIntent: "account.delete.intent",
    accountDeleteComplete: "account.delete.complete",
  },
}));

import {
  ACCOUNT_ERASURE_ROOT_OWNER_REGISTRY,
  eraseUserAccount,
  isAccountErasureResumable,
  verifyRetainedAccountErasureEvents,
} from "../accountDeletion.js";

type Operation =
  | { op: "create"; path: string; data: Record<string, unknown> }
  | { op: "set"; path: string; data: Record<string, unknown>; options?: { merge?: boolean } }
  | { op: "delete"; path: string }
  | { op: "commit"; path: string };
type WriteOperation = Extract<Operation, { op: "create" }> | Extract<Operation, { op: "set" }>;

function fakeDb({
  operations = [],
  failErasureAuditSet = false,
  erasureAuditStatus,
  erasureAuditSchemaVersion,
}: {
  operations?: Operation[];
  failErasureAuditSet?: boolean;
  erasureAuditStatus?: string;
  erasureAuditSchemaVersion?: number;
} = {}) {
  const documents = new Map<string, Record<string, unknown>>();
  const auditPathPrefix = "account_erasure_audit/";
  if (erasureAuditStatus !== undefined) {
    documents.set("__audit_seed__", {
      status: erasureAuditStatus,
      schemaVersion: erasureAuditSchemaVersion ?? 2,
    });
  }
  const makeDoc = (path: string) => ({
    path,
    get: vi.fn(async () => {
      const data =
        path.startsWith(auditPathPrefix) && !path.includes("/events/") && documents.has("__audit_seed__")
          ? documents.get("__audit_seed__")
          : documents.get(path);
      return { exists: data !== undefined, get: (field: string) => data?.[field] };
    }),
    set: vi.fn(async (data: Record<string, unknown>, options?: { merge?: boolean }) => {
      if (failErasureAuditSet && path.startsWith("account_erasure_audit/")) {
        throw new Error("durable erasure audit unavailable");
      }
      operations.push({ op: "set", path, data, options });
      documents.set(path, options?.merge ? { ...documents.get(path), ...data } : { ...data });
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
    batch: () => {
      const pending: Array<() => void> = [];
      return {
        create: vi.fn((ref: { path?: string }, data: Record<string, unknown>) => {
          const path = ref.path ?? "";
          operations.push({ op: "create", path, data });
          pending.push(() => documents.set(path, { ...data }));
        }),
        set: vi.fn((ref: { path?: string }, data: Record<string, unknown>, options?: { merge?: boolean }) => {
          const path = ref.path ?? "";
          operations.push({ op: "set", path, data, options });
          pending.push(() => documents.set(path, options?.merge ? { ...documents.get(path), ...data } : { ...data }));
        }),
        delete: vi.fn((ref: { path?: string }) => {
          const path = ref.path ?? "";
          operations.push({ op: "delete", path });
          pending.push(() => documents.delete(path));
        }),
        commit: vi.fn(async () => {
          if (failErasureAuditSet && operations.some((operation) => operation.path.startsWith(auditPathPrefix))) {
            throw new Error("durable erasure audit unavailable");
          }
          for (const apply of pending) apply();
          pending.length = 0;
          operations.push({ op: "commit", path: "batch" });
        }),
      };
    },
  };
}

type AccountDeletionAuditAppender = (
  uid: string,
  event: { actor: string; action: string; domain: string },
) => Promise<unknown>;

function baseOptions(
  overrides: Partial<{
    deleteAuthUser: () => Promise<void>;
    revokeAuthTokens: () => Promise<void>;
    appendAuditEventRequired: AccountDeletionAuditAppender;
    deleteStorageObjects: (prefix: string) => Promise<void>;
    destroyCredential: (secretVersionName: string) => Promise<void>;
    useDefaultStorage: boolean;
  }> = {},
) {
  return {
    ...(overrides.useDefaultStorage
      ? {}
      : { deleteStorageObjects: overrides.deleteStorageObjects ?? (async () => {}) }),
    destroyCredential: overrides.destroyCredential ?? (async () => {}),
    deleteAuthUser: overrides.deleteAuthUser ?? (async () => {}),
    revokeAuthTokens: overrides.revokeAuthTokens ?? (async () => {}),
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
    listStorageFiles.mockResolvedValue([[]]);
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
        (operation.op === "create" || operation.op === "set") &&
        operation.path.startsWith("account_erasure_audit/") &&
        operation.data.status === "intent_recorded",
    );
    const userTreeDeleteIndex = operations.findIndex(
      (operation) => operation.op === "delete" && operation.path === "users/u1",
    );

    expect(erasureAuditIntentIndex).toBeGreaterThanOrEqual(0);
    expect(userTreeDeleteIndex).toBeGreaterThanOrEqual(0);
    expect(erasureAuditIntentIndex).toBeLessThan(userTreeDeleteIndex);
    const tombstoneIndex = operations.findIndex(
      (operation) => operation.op === "set" && operation.path === "account_erasure_tombstones/u1",
    );
    expect(tombstoneIndex).toBeGreaterThan(erasureAuditIntentIndex);
    expect(tombstoneIndex).toBeLessThan(userTreeDeleteIndex);
  });

  it("revokes sessions before external cleanup begins", async () => {
    const revokeAuthTokens = vi.fn(async () => {});
    const deleteStorageObjects = vi.fn(async () => {
      expect(revokeAuthTokens).toHaveBeenCalledTimes(1);
    });
    await eraseUserAccount(fakeDb(), "u1", baseOptions({ revokeAuthTokens, deleteStorageObjects }));
    expect(revokeAuthTokens).toHaveBeenCalledWith("u1");
  });

  it("keeps the complete retained intent and completion events", async () => {
    const operations: Operation[] = [];
    await eraseUserAccount(fakeDb({ operations }), "u1", baseOptions());
    const retainedEvents = operations.filter(
      (operation): operation is Extract<Operation, { op: "create" }> =>
        operation.op === "create" && operation.path.includes("/events/"),
    );
    expect(retainedEvents.map((operation) => operation.data.eventKind)).toEqual(["intent", "completion"]);
    for (const operation of retainedEvents) {
      expect(operation.data).toMatchObject({
        seq: expect.any(Number),
        ts: expect.any(String),
        actor: expect.any(String),
        action: expect.any(String),
        domain: "account",
        prevHash: expect.any(String),
        hash: expect.stringMatching(/^[a-f0-9]{64}$/u),
      });
    }
    const events = retainedEvents.map((operation) => ({
      seq: Number(operation.data.seq),
      ts: String(operation.data.ts),
      actor: String(operation.data.actor),
      action: String(operation.data.action),
      domain: String(operation.data.domain),
      prevHash: String(operation.data.prevHash),
      hash: String(operation.data.hash),
    }));
    const head = String(events[1]?.hash ?? "");
    expect(verifyRetainedAccountErasureEvents(events, head)).toBe(true);
    expect(verifyRetainedAccountErasureEvents(events.slice(0, 1), head)).toBe(false);
    expect(verifyRetainedAccountErasureEvents(events, events[0]?.hash ?? "")).toBe(false);
    const [intent, completion] = events;
    if (!intent || !completion) throw new Error("Expected retained intent and completion events.");
    expect(
      verifyRetainedAccountErasureEvents(
        [{ ...intent, actor: "attacker" }, completion],
        head,
      ),
    ).toBe(false);
  });

  it("tracks every known UID-owned root collection in the erasure registry", () => {
    expect(ACCOUNT_ERASURE_ROOT_OWNER_REGISTRY).toEqual([
      { collection: "voip_outbound", ownerField: "uid" },
      { collection: "fcm_outbound", ownerField: "uid" },
      { collection: "credential_transfers", ownerField: "ownerUid" },
      { collection: "hermes_gateway_token_index", ownerField: "uid" },
      { collection: "hermes_gateway_device_sessions", ownerField: "uid" },
      { collection: "cli_link_sessions", ownerField: "ownerUid" },
    ]);
    const credentialTransfer = readFileSync(resolve(__dirname, "../callables/credentialTransfer.ts"), "utf8");
    const hermesApproval = readFileSync(resolve(__dirname, "../callables/hermesGatewayApprove.ts"), "utf8");
    const cliLink = readFileSync(resolve(__dirname, "../callables/cliLink.ts"), "utf8");
    expect(credentialTransfer).toContain("ownerUid: uid");
    expect(hermesApproval).toContain("uid: input.uid");
    expect(cliLink).toContain("ownerUid: uid");
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
      .filter(
        (operation): operation is WriteOperation =>
          operation.op === "create" || operation.op === "set",
      )
      .filter(
        (operation) =>
          operation.path.startsWith("account_erasure_audit/") && !operation.path.includes("/events/"),
      )
      .map((operation) => operation.data.status);

    expect(result.deletedAuthUser).toBe(true);
    expect(result.cloudDataDeleted).toBe(true);
    expect(result.retryRequired).toBe(false);
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
      (operation): operation is WriteOperation =>
        (operation.op === "create" || operation.op === "set") &&
        operation.path.startsWith("account_erasure_audit/"),
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
    ).toMatchObject({
      op: "set",
      data: expect.objectContaining({ status: "auth_user_already_missing" }),
    });
    expect(appendAuditEvent).not.toHaveBeenCalled();
  });

  it("records incomplete storage erasure and preserves Auth for an idempotent retry", async () => {
    const operations: Operation[] = [];
    const deleteAuthUser = vi.fn(async () => {});
    const deleteStorageObjects = vi.fn(async (prefix: string) => {
      if (prefix.startsWith("users/")) throw new Error("storage unavailable");
    });

    const result = await eraseUserAccount(
      fakeDb({ operations }),
      "u1",
      baseOptions({ deleteAuthUser, deleteStorageObjects }),
    );

    expect(result).toMatchObject({
      cloudDataDeleted: false,
      retryRequired: true,
      failedStorageDeletes: 1,
      failedStoragePrefixKinds: ["user_data"],
      deletedAuthUser: false,
    });
    expect(deleteAuthUser).not.toHaveBeenCalled();
    expect(operations).not.toContainEqual({ op: "delete", path: "users/u1" });
    expect(
      operations.find(
        (operation) =>
          operation.op === "set" &&
          operation.path.startsWith("account_erasure_audit/") &&
          operation.data.status === "external_cleanup_incomplete" &&
          operation.data.retryRequired === true,
      ),
    ).toMatchObject({
      op: "set",
      data: expect.objectContaining({
        status: "external_cleanup_incomplete",
        retryRequired: true,
      }),
    });
  });

  it("fails closed when post-delete Storage verification still finds an object", async () => {
    const deleteAuthUser = vi.fn(async () => {});
    listStorageFiles.mockResolvedValueOnce([[{ name: "residual" }]]);

    const result = await eraseUserAccount(fakeDb(), "u1", baseOptions({ deleteAuthUser, useDefaultStorage: true }));

    expect(deleteStorageFiles).toHaveBeenCalledTimes(2);
    expect(result).toMatchObject({
      cloudDataDeleted: false,
      retryRequired: true,
      failedStorageDeletes: 1,
      failedStoragePrefixKinds: ["user_data"],
      deletedAuthUser: false,
    });
    expect(deleteAuthUser).not.toHaveBeenCalled();
  });

  it.each([
    "intent_recorded",
    "external_cleanup_incomplete",
    "cloud_data_cleanup_failed",
    "cloud_data_deleted",
    "auth_delete_failed",
    "session_revoke_failed",
  ])("treats nonterminal audit status %s as retry authorization", async (status) => {
    await expect(isAccountErasureResumable(fakeDb({ erasureAuditStatus: status }), "u1")).resolves.toBe(true);
  });

  it.each([undefined, "account_deleted", "auth_user_already_missing", "unknown"])(
    "does not authorize a retry from terminal or unknown status %s",
    async (status) => {
      await expect(isAccountErasureResumable(fakeDb({ erasureAuditStatus: status }), "u1")).resolves.toBe(false);
    },
  );

  it("refuses to overwrite a legacy nonterminal receipt", async () => {
    const operations: Operation[] = [];
    await expect(
      eraseUserAccount(
        fakeDb({
          operations,
          erasureAuditStatus: "cloud_data_deleted_with_secret_destroy_failures",
          erasureAuditSchemaVersion: 1,
        }),
        "u1",
        baseOptions(),
      ),
    ).rejects.toThrow(/operator review/iu);
    expect(appendAuditEventRequired).not.toHaveBeenCalled();
    expect(operations).toHaveLength(0);
  });
});
