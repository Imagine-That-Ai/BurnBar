import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

type StoredDoc = Record<string, unknown>;

const { localStore, dbMock } = vi.hoisted(() => {
  const docs = new Map<string, StoredDoc>();
  const transactionWrites: Array<Array<{ path: string; data: StoredDoc }>> = [];

  function directChildren(collectionPath: string) {
    const prefix = `${collectionPath}/`;
    return [...docs.entries()]
      .filter(([path]) => path.startsWith(prefix) && path.slice(prefix.length).includes("/") === false)
      .map(([path, data]) => ({
        id: path.slice(prefix.length),
        path,
        data: () => data,
      }));
  }

  function makeCollection(path: string) {
    return {
      doc: (id: string) => ({ path: `${path}/${id}` }),
      orderBy: (field: string, direction: "asc" | "desc") => ({
        limit: (limit: number) => ({
          __query: { path, field, direction, limit },
        }),
      }),
    };
  }

  const dbMock = {
    collection: makeCollection,
    doc: (path: string) => ({ path }),
    runTransaction: vi.fn(async (fn: (tx: unknown) => Promise<unknown>) => {
      const pending: Array<{ path: string; data: StoredDoc; merge?: boolean }> = [];
      const tx = {
        get: async (query: { __query: { path: string; field: string; direction: "asc" | "desc"; limit: number } }) => {
          const { path, field, direction, limit } = query.__query;
          const sorted = directChildren(path).sort((a, b) => {
            const av = typeof a.data()[field] === "number" ? (a.data()[field] as number) : -1;
            const bv = typeof b.data()[field] === "number" ? (b.data()[field] as number) : -1;
            return direction === "desc" ? bv - av : av - bv;
          });
          return { docs: sorted.slice(0, limit) };
        },
        set: (ref: { path: string }, data: StoredDoc, options?: { merge?: boolean }) => {
          pending.push({ path: ref.path, data, merge: options?.merge });
        },
      };
      const result = await fn(tx);
      const committed = pending.map(({ path, data, merge }) => {
        const next = merge ? { ...(docs.get(path) ?? {}), ...data } : data;
        docs.set(path, next);
        return { path, data: next };
      });
      transactionWrites.push(committed);
      return result;
    }),
  };

  return {
    dbMock,
    localStore: {
      docs,
      transactionWrites,
      readCollection: directChildren,
      readDoc: (path: string) => docs.get(path) ?? null,
      reset: () => {
        docs.clear();
        transactionWrites.length = 0;
      },
    },
  };
});

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));

vi.mock("../adminRuntime.js", () => ({
  db: dbMock,
  auth: {},
}));

import { appendAuditEventRequired, AUDIT_ACTIONS, verifyAuditChain } from "../callables/auditLog.js";

function writeEvidenceArtifact(value: unknown) {
  const directory = process.env.OPENBURNBAR_LINUX_SECURITY_EVIDENCE_DIR;
  if (!directory) return;
  mkdirSync(directory, { recursive: true });
  writeFileSync(
    join(directory, "high-risk-owner-action-audit-local-store-transcript.json"),
    `${JSON.stringify(value, null, 2)}\n`,
  );
}

describe("high-risk owner action audit persistence", () => {
  it("writes and reads back unified_audit_log plus audit_meta/head through the product append path", async () => {
    localStore.reset();
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-04T00:00:00.000Z"));

    try {
      const event = await appendAuditEventRequired("u1", {
        actor: "user:linux",
        action: AUDIT_ACTIONS.highRiskOwnerAction,
        domain: "provider_account_delete:anthropic_default",
      });
      await appendAuditEventRequired("u1", {
        actor: "user:linux",
        action: AUDIT_ACTIONS.highRiskOwnerAction,
        domain: "revoke_all_access:all",
      });

      const readback = localStore
        .readCollection("users/u1/unified_audit_log")
        .map((doc) => doc.data())
        .sort((a, b) => Number(a.seq) - Number(b.seq));
      const head = localStore.readDoc("users/u1/audit_meta/head");
      const verification = verifyAuditChain(
        readback.map((doc) => ({
          seq: Number(doc.seq),
          ts: String(doc.ts),
          actor: String(doc.actor),
          action: String(doc.action),
          domain: String(doc.domain),
          prevHash: String(doc.prevHash),
          hash: String(doc.hash),
        })),
        head
          ? {
              maxSeq: Number(head.maxSeq),
              headHash: String(head.headHash),
            }
          : null,
      );

      expect(event.action).toBe("security.high_risk_owner_action");
      expect(readback).toHaveLength(2);
      expect(readback[0]).toMatchObject({
        seq: 0,
        ts: "2026-07-04T00:00:00.000Z",
        actor: "user:linux",
        action: "security.high_risk_owner_action",
        domain: "provider_account_delete:anthropic_default",
        prevHash: "",
      });
      expect(readback[1]).toMatchObject({
        seq: 1,
        ts: "2026-07-04T00:00:00.000Z",
        action: "security.high_risk_owner_action",
        domain: "revoke_all_access:all",
        prevHash: readback[0].hash,
      });
      expect(head).toMatchObject({ maxSeq: 1, headHash: readback[1].hash });
      expect(verification).toEqual({ valid: true, verifiedMaxSeq: 1 });
      expect(localStore.transactionWrites).toHaveLength(2);
      expect(localStore.transactionWrites[0].map((write) => write.path)).toEqual([
        "users/u1/unified_audit_log/000000000000",
        "users/u1/audit_meta/head",
      ]);

      writeEvidenceArtifact({
        target: "VAL-CLOUD-002",
        source: "appendAuditEventRequired product path with deterministic local Firestore store",
        collections: {
          unified_audit_log: readback.map((doc) => ({
            seq: doc.seq,
            ts: doc.ts,
            actor: doc.actor,
            action: doc.action,
            domain: doc.domain,
            prevHash: doc.prevHash,
            hash: doc.hash,
          })),
          audit_meta: { head },
        },
        transactionWrites: localStore.transactionWrites.map((writes) => writes.map((write) => write.path)),
        verification,
      });
    } finally {
      vi.useRealTimers();
    }
  });
});
