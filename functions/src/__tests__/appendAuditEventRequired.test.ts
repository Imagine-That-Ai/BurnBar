/**
 * B-SEC-3 fail-closed primitive: `appendAuditEventRequired` must THROW when the
 * underlying transactional append fails (NO try/catch), so irreversible-action
 * callers refuse the action instead of silently dropping the audit record. The
 * best-effort `appendAuditEvent` shares the same write path, so this also proves
 * the head pointer is advanced in the same transaction as the event.
 */
import { describe, expect, it, vi } from "vitest";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

// `vi.hoisted` builds the fake `db` BEFORE the hoisted `vi.mock` factory runs,
// so the factory can close over it. Capture transaction writes to assert the
// head doc is advanced in the SAME transaction as the event append.
const { writes, runTransaction, failingRunTransaction, dbMock } = vi.hoisted(() => {
  const writes: Array<{ path: string; data: Record<string, unknown> }> = [];
  const makeRef = (path: string) => ({ path, set: () => undefined });
  const runTransaction = vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => {
    // A fresh chain: the tail query returns no docs (seq starts at 0).
    const tx = {
      get: async () => ({ docs: [] as unknown[] }),
      set: (ref: { path: string }, data: Record<string, unknown>) => {
        writes.push({ path: ref.path, data });
      },
    };
    return fn(tx);
  });
  const failingRunTransaction = vi.fn(async () => {
    throw new Error("firestore transaction failed");
  });
  const dbMock: {
    runTransaction: typeof runTransaction;
    collection: (path: string) => unknown;
    doc: (path: string) => unknown;
  } = {
    runTransaction,
    collection: (path: string) => ({
      orderBy: () => ({ limit: () => ({}) }),
      doc: (id: string) => makeRef(`${path}/${id}`),
    }),
    doc: (path: string) => makeRef(path),
  };
  return { writes, runTransaction, failingRunTransaction, dbMock };
});

vi.mock("../adminRuntime.js", () => ({
  db: dbMock,
  auth: {},
}));

import { appendAuditEvent, appendAuditEventRequired } from "../callables/auditLog.js";

describe("appendAuditEvent — transactional head advance", () => {
  it("writes the event AND advances audit_meta/head in the same transaction", async () => {
    writes.length = 0;
    const result = await appendAuditEvent("u1", { actor: "user", action: "data.export", domain: "all" });
    expect(result.seq).toBe(0);

    const eventWrite = writes.find((w) => w.path.includes("unified_audit_log"));
    const headWrite = writes.find((w) => w.path.endsWith("audit_meta/head"));
    expect(eventWrite).toBeDefined();
    expect(headWrite).toBeDefined();
    // The head pins the chain length to the just-appended seq + its hash.
    expect(headWrite?.data.maxSeq).toBe(0);
    expect(headWrite?.data.headHash).toBe(result.hash);
  });
});

describe("appendAuditEventRequired — fail-closed", () => {
  it("propagates the error when the transactional append fails", async () => {
    dbMock.runTransaction = failingRunTransaction;
    try {
      await expect(
        appendAuditEventRequired("u1", { actor: "user", action: "data.export", domain: "all" }),
      ).rejects.toThrow(/firestore transaction failed/);
    } finally {
      dbMock.runTransaction = runTransaction;
    }
  });
});
