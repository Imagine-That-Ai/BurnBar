/**
 * Regression: provider-quota refresh sweep (crosscut-010).
 *
 * The originally-filed fix proposed replacing the second "compatibility pass"
 * of refreshAllProviderQuotas with `.where("lastRefreshAt", "==", null)`.
 * That filter is FUNCTIONALLY WRONG: Firestore `== null` matches only
 * explicit-null fields, while the docs the pass exists to drain have the
 * field MISSING entirely (legacy docs that predate `lastRefreshAt`). The
 * ordered pass-1 query (`orderBy("lastRefreshAt", "asc")`) also excludes
 * missing-field docs, so shipping that sketch would have returned zero rows
 * and permanently orphaned every legacy account doc.
 *
 * The corrected design implemented by `runQuotaRefreshSweep`:
 *   1. A cursor-resumable, self-terminating backfill stamps
 *      `lastRefreshAt: null` onto missing-field docs (cheap writes, no HTTP),
 *      so they join the ordered pass — explicit null sorts FIRST in the asc
 *      orderBy, and the existing composite index already covers it. Once a
 *      clean scan finds nothing left, a marker doc retires the backfill to a
 *      single cached read per run (zero extra collection-group queries).
 *   2. The refresh pass itself runs through a bounded concurrency pool
 *      instead of strictly serial awaits.
 *
 * The fakes below intentionally reproduce Firestore's `== null` /
 * orderBy-missing-field semantics so the orphaning failure mode stays
 * encoded: if someone "simplifies" the sweep back to the `== null` filter,
 * these tests fail.
 */
import { beforeEach, describe, expect, it } from "vitest";

import {
  LAST_REFRESH_AT_BACKFILL_MARKER_PATH,
  mapWithConcurrency,
  resetQuotaRefreshSweepCachesForTests,
  runQuotaRefreshSweep,
  type SweepAccountDoc,
  type SweepDb,
  type SweepDocRef,
  type SweepMarkerSnapshot,
  type SweepQuery,
  type SweepQuerySnapshot,
} from "../quotaRefreshSweep.js";

type Doc = Record<string, unknown>;

/**
 * Minimal in-memory model of the `provider_accounts` /
 * `provider_connections` collection groups plus top-level marker docs,
 * faithful to the Firestore behaviors this regression hinges on:
 *
 * - `where(field, "==", null)` matches ONLY explicit-null fields — a missing
 *   field never matches.
 * - `orderBy(field, "asc")` EXCLUDES docs missing the field, and sorts
 *   explicit nulls before every present value.
 * - Queries without `orderBy` return docs in implicit `__name__` (path)
 *   order; `startAfter(snapshot)` positions after that doc's path.
 */
class FakeSweepDb {
  /** path -> fields. Collection-group membership derives from the path. */
  readonly store = new Map<string, Doc>();
  readonly queryLog: Array<{ group: string; filters: string[]; ordered: boolean }> = [];
  readonly updateLog: string[] = [];

  collectionGroup(group: string): SweepQuery<FakeSweepDoc> {
    return new FakeQuery(this, group, [], undefined, undefined, undefined);
  }

  doc(path: string): SweepDocRef {
    const db = this;
    return {
      async get(): Promise<SweepMarkerSnapshot> {
        const data = db.store.get(path);
        return {
          exists: data !== undefined,
          // Real DocumentSnapshot exposes its location via `ref.path`.
          ref: { path },
          data: () => (data === undefined ? undefined : { ...data }),
        };
      },
      async set(data: Record<string, unknown>) {
        db.store.set(path, { ...data });
      },
    };
  }

  /** Docs belonging to a collection group, in implicit path order. */
  groupDocs(group: string): Array<{ path: string; data: Doc }> {
    return [...this.store.entries()]
      .filter(([path]) => {
        const segments = path.split("/");
        return segments.length >= 2 && segments.at(-2) === group;
      })
      .map(([path, data]) => ({ path, data }))
      .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  }

  makeDoc(path: string): FakeSweepDoc {
    return new FakeSweepDoc(this, path);
  }
}

class FakeSweepDoc {
  constructor(
    private readonly db: FakeSweepDb,
    readonly path: string,
  ) {}

  get ref() {
    const db = this.db;
    const path = this.path;
    return {
      path,
      async update(data: Record<string, unknown>) {
        const existing = db.store.get(path);
        if (existing === undefined) throw new Error(`NOT_FOUND: ${path}`);
        db.updateLog.push(path);
        db.store.set(path, { ...existing, ...data });
      },
    };
  }

  get(field: string): unknown {
    return this.db.store.get(this.path)?.[field];
  }

  data(): Doc {
    return { ...(this.db.store.get(this.path) ?? {}) };
  }
}

class FakeQuery implements SweepQuery<FakeSweepDoc> {
  constructor(
    private readonly db: FakeSweepDb,
    private readonly group: string,
    private readonly filters: Array<{ field: string; op: "==" | "in"; value: unknown }>,
    private readonly orderField: string | undefined,
    private readonly limitCount: number | undefined,
    private readonly startAfterPath: string | undefined,
  ) {}

  where(field: string, op: "==" | "in", value: unknown): FakeQuery {
    return new FakeQuery(
      this.db,
      this.group,
      [...this.filters, { field, op, value }],
      this.orderField,
      this.limitCount,
      this.startAfterPath,
    );
  }

  orderBy(field: string): FakeQuery {
    return new FakeQuery(this.db, this.group, this.filters, field, this.limitCount, this.startAfterPath);
  }

  limit(count: number): FakeQuery {
    return new FakeQuery(this.db, this.group, this.filters, this.orderField, count, this.startAfterPath);
  }

  startAfter(cursor: unknown): FakeQuery {
    let path: string | undefined;
    if (typeof cursor === "object" && cursor !== null && "ref" in cursor) {
      const ref = cursor.ref;
      if (typeof ref === "object" && ref !== null && "path" in ref && typeof ref.path === "string") {
        path = ref.path;
      }
    }
    return new FakeQuery(this.db, this.group, this.filters, this.orderField, this.limitCount, path);
  }

  async get(): Promise<SweepQuerySnapshot<FakeSweepDoc>> {
    this.db.queryLog.push({
      group: this.group,
      filters: this.filters.map((f) => `${f.field}${f.op}${JSON.stringify(f.value)}`),
      ordered: this.orderField !== undefined,
    });

    let rows = this.db.groupDocs(this.group).filter(({ data }) =>
      this.filters.every(({ field, op, value }) => {
        if (!(field in data)) return false; // missing field never matches — Firestore semantics
        if (op === "==") return data[field] === value;
        return Array.isArray(value) && value.includes(data[field]);
      }),
    );

    const orderField = this.orderField;
    if (orderField !== undefined) {
      // orderBy EXCLUDES docs missing the field; explicit null sorts first.
      rows = rows
        .filter(({ data }) => orderField in data)
        .sort((a, b) => {
          const av = a.data[orderField];
          const bv = b.data[orderField];
          if (av === bv) return a.path < b.path ? -1 : 1;
          if (av === null) return -1;
          if (bv === null) return 1;
          return String(av) < String(bv) ? -1 : 1;
        });
    }

    if (this.startAfterPath !== undefined) {
      const cursorPath = this.startAfterPath;
      rows = rows.filter(({ path }) => path > cursorPath);
    }
    if (this.limitCount !== undefined) {
      rows = rows.slice(0, this.limitCount);
    }
    return { docs: rows.map(({ path }) => this.db.makeDoc(path)) };
  }
}

function accountPath(uid: string, accountID: string): string {
  return `users/${uid}/provider_accounts/${accountID}`;
}

function connectionPath(uid: string, provider: string): string {
  return `users/${uid}/provider_connections/${provider}`;
}

function seedAccount(db: FakeSweepDb, uid: string, accountID: string, fields: Doc): string {
  const path = accountPath(uid, accountID);
  db.store.set(path, { status: "connected", storageScope: "cloud_refreshable", ...fields });
  return path;
}

type SweepCalls = {
  refreshedAccounts: string[];
  refreshedLegacy: string[];
};

function sweepOptions(db: FakeSweepDb, calls: SweepCalls, batchSize = 20, concurrency = 5) {
  return {
    batchSize,
    concurrency,
    refreshAccountDoc: async (doc: FakeSweepDoc) => {
      calls.refreshedAccounts.push(doc.path);
      // The real refresher always stamps lastRefreshAt (success and failure paths).
      db.store.set(doc.path, { ...db.store.get(doc.path), lastRefreshAt: new Date().toISOString() });
    },
    legacyKeyForAccountDoc: (doc: FakeSweepDoc) => {
      const parts = doc.path.split("/");
      return `${parts[1]}/${String(doc.data().providerID ?? "")}`;
    },
    refreshLegacyConnectionDoc: async (doc: FakeSweepDoc) => {
      calls.refreshedLegacy.push(doc.path);
    },
    legacyKeyForConnectionDoc: (doc: FakeSweepDoc) => {
      const parts = doc.path.split("/");
      return `${parts[1]}/${parts[3]}`;
    },
  };
}

function asSweepDb(db: FakeSweepDb): SweepDb<FakeSweepDoc> {
  return db;
}

beforeEach(() => {
  resetQuotaRefreshSweepCachesForTests();
});

describe("the verifier-proven orphaning failure mode (encoded against the fake's Firestore semantics)", () => {
  it("`where('lastRefreshAt', '==', null)` returns ZERO rows for legacy missing-field docs", async () => {
    const db = new FakeSweepDb();
    seedAccount(db, "legacy-user", "acct-1", {}); // lastRefreshAt MISSING — the pass-2 population
    seedAccount(db, "fresh-user", "acct-2", { lastRefreshAt: "2026-06-09T00:00:00.000Z" });

    const snap = await db
      .collectionGroup("provider_accounts")
      .where("status", "==", "connected")
      .where("storageScope", "in", ["cloud_refreshable", "server_private"])
      .where("lastRefreshAt", "==", null)
      .get();

    // The filed sketch would have refreshed exactly these zero rows, forever.
    expect(snap.docs).toEqual([]);
  });

  it("the ordered pass-1 query also excludes missing-field docs (both query shapes orphan them)", async () => {
    const db = new FakeSweepDb();
    const legacyPath = seedAccount(db, "legacy-user", "acct-1", {});
    seedAccount(db, "fresh-user", "acct-2", { lastRefreshAt: "2026-06-09T00:00:00.000Z" });

    const snap = await db
      .collectionGroup("provider_accounts")
      .where("status", "==", "connected")
      .where("storageScope", "in", ["cloud_refreshable", "server_private"])
      .orderBy("lastRefreshAt")
      .limit(20)
      .get();

    expect(snap.docs.map((doc) => doc.path)).not.toContain(legacyPath);
  });

  it("explicit null sorts FIRST in the asc orderBy, so backfilled docs get stale-first priority", async () => {
    const db = new FakeSweepDb();
    const backfilled = seedAccount(db, "legacy-user", "acct-1", { lastRefreshAt: null });
    const fresh = seedAccount(db, "fresh-user", "acct-2", { lastRefreshAt: "2026-06-09T00:00:00.000Z" });

    const snap = await db
      .collectionGroup("provider_accounts")
      .where("status", "==", "connected")
      .where("storageScope", "in", ["cloud_refreshable", "server_private"])
      .orderBy("lastRefreshAt")
      .limit(20)
      .get();

    expect(snap.docs.map((doc) => doc.path)).toEqual([backfilled, fresh]);
  });
});

describe("runQuotaRefreshSweep backfill (the corrected design)", () => {
  it("backfills legacy missing-field docs to explicit null and refreshes them in the same run", async () => {
    const db = new FakeSweepDb();
    const legacyPath = seedAccount(db, "legacy-user", "acct-1", {});
    seedAccount(db, "fresh-user", "acct-2", { lastRefreshAt: "2026-06-09T00:00:00.000Z" });

    const calls: SweepCalls = { refreshedAccounts: [], refreshedLegacy: [] };
    const result = await runQuotaRefreshSweep(asSweepDb(db), sweepOptions(db, calls));

    // The legacy doc was NOT orphaned: stamped null, then refreshed FIRST
    // (null sorts before every present lastRefreshAt value).
    expect(result.backfill.backfilled).toBe(1);
    expect(calls.refreshedAccounts[0]).toBe(legacyPath);
    expect(calls.refreshedAccounts).toHaveLength(2);
  });

  it("marks the migration complete and stops issuing backfill scan queries on later runs", async () => {
    const db = new FakeSweepDb();
    seedAccount(db, "legacy-user", "acct-1", {});

    const calls: SweepCalls = { refreshedAccounts: [], refreshedLegacy: [] };
    const first = await runQuotaRefreshSweep(asSweepDb(db), sweepOptions(db, calls));
    expect(first.backfill.complete).toBe(true);
    expect(db.store.get(LAST_REFRESH_AT_BACKFILL_MARKER_PATH)?.complete).toBe(true);

    // Second run: the marker (cached in-process) retires the scan entirely.
    db.queryLog.length = 0;
    const second = await runQuotaRefreshSweep(asSweepDb(db), sweepOptions(db, calls));
    expect(second.backfill.skipped).toBe(true);
    const backfillScans = db.queryLog.filter((entry) => !entry.ordered && entry.group === "provider_accounts");
    expect(backfillScans).toEqual([]);
  });

  it("honors a persisted complete marker across cold starts (one marker read, zero scans)", async () => {
    const db = new FakeSweepDb();
    db.store.set(LAST_REFRESH_AT_BACKFILL_MARKER_PATH, { complete: true });
    seedAccount(db, "fresh-user", "acct-2", { lastRefreshAt: "2026-06-09T00:00:00.000Z" });

    const calls: SweepCalls = { refreshedAccounts: [], refreshedLegacy: [] };
    const result = await runQuotaRefreshSweep(asSweepDb(db), sweepOptions(db, calls));
    expect(result.backfill.skipped).toBe(true);
    expect(db.queryLog.filter((entry) => !entry.ordered && entry.group === "provider_accounts")).toEqual([]);
  });

  it("pages with persisted cursors and never re-examines docs it already scanned", async () => {
    const db = new FakeSweepDb();
    // 5 legacy docs in one status/scope stream with a scan page size of 2.
    for (let i = 0; i < 5; i += 1) {
      seedAccount(db, "legacy-user", `acct-${i}`, {});
    }

    const calls: SweepCalls = { refreshedAccounts: [], refreshedLegacy: [] };
    const options = { ...sweepOptions(db, calls, 0), backfillScanPageSize: 2 };

    const first = await runQuotaRefreshSweep(asSweepDb(db), options);
    expect(first.backfill.backfilled).toBe(2);
    expect(first.backfill.complete).toBe(false);

    const second = await runQuotaRefreshSweep(asSweepDb(db), options);
    expect(second.backfill.backfilled).toBe(2);
    expect(second.backfill.complete).toBe(false);

    const third = await runQuotaRefreshSweep(asSweepDb(db), options);
    expect(third.backfill.backfilled).toBe(1);

    // Every legacy doc was stamped exactly once — the cursor prevented rescans.
    expect(db.updateLog).toHaveLength(5);
    expect(new Set(db.updateLog).size).toBe(5);

    // A short final page completes the stream; the next run is scan-free.
    const fourth = await runQuotaRefreshSweep(asSweepDb(db), options);
    expect(fourth.backfill.complete === true || fourth.backfill.skipped === true).toBe(true);
  });

  it("survives a doc deleted between scan and stamp (NOT_FOUND is skipped, the sweep continues)", async () => {
    const db = new FakeSweepDb();
    const doomed = seedAccount(db, "legacy-user", "acct-doomed", {});
    seedAccount(db, "legacy-user", "acct-kept", {});

    const calls: SweepCalls = { refreshedAccounts: [], refreshedLegacy: [] };
    // batchSize 0: isolate the backfill so the refresh pass does not restamp
    // the surviving doc with a fresh ISO timestamp.
    const options = sweepOptions(db, calls, 0);
    // Sabotage: deleting the doc after the scan sees it makes ref.update throw.
    const originalMakeDoc = db.makeDoc.bind(db);
    db.makeDoc = (path: string) => {
      if (path === doomed) db.store.delete(path);
      return originalMakeDoc(path);
    };

    const result = await runQuotaRefreshSweep(asSweepDb(db), options);
    expect(result.backfill.backfilled).toBe(1);
    expect(db.store.get(accountPath("legacy-user", "acct-kept"))?.lastRefreshAt).toBeNull();
  });
});

describe("runQuotaRefreshSweep refresh pass", () => {
  it("respects the batch budget across statuses, stale-first", async () => {
    const db = new FakeSweepDb();
    seedAccount(db, "u1", "a1", { lastRefreshAt: "2026-06-01T00:00:00.000Z" });
    seedAccount(db, "u2", "a2", { lastRefreshAt: "2026-06-02T00:00:00.000Z" });
    seedAccount(db, "u3", "a3", { status: "stale", lastRefreshAt: "2026-05-01T00:00:00.000Z" });
    seedAccount(db, "u4", "a4", { status: "error", lastRefreshAt: "2026-05-02T00:00:00.000Z" });

    const calls: SweepCalls = { refreshedAccounts: [], refreshedLegacy: [] };
    await runQuotaRefreshSweep(asSweepDb(db), sweepOptions(db, calls, 3));

    expect(calls.refreshedAccounts).toHaveLength(3);
    // Status pass order is connected -> stale -> error; budget exhausts at 3.
    expect(calls.refreshedAccounts).toEqual([
      accountPath("u1", "a1"),
      accountPath("u2", "a2"),
      accountPath("u3", "a3"),
    ]);
  });

  it("runs refreshes through the concurrency pool, not serially", async () => {
    const db = new FakeSweepDb();
    for (let i = 0; i < 8; i += 1) {
      seedAccount(db, `u${i}`, `a${i}`, { lastRefreshAt: `2026-06-0${(i % 8) + 1}T00:00:00.000Z` });
    }

    let inFlight = 0;
    let maxInFlight = 0;
    const calls: SweepCalls = { refreshedAccounts: [], refreshedLegacy: [] };
    const options = {
      ...sweepOptions(db, calls, 8, 4),
      refreshAccountDoc: async (doc: FakeSweepDoc) => {
        inFlight += 1;
        maxInFlight = Math.max(maxInFlight, inFlight);
        await new Promise((resolve) => setTimeout(resolve, 5));
        calls.refreshedAccounts.push(doc.path);
        inFlight -= 1;
      },
    };

    await runQuotaRefreshSweep(asSweepDb(db), options);

    expect(calls.refreshedAccounts).toHaveLength(8);
    expect(maxInFlight).toBeGreaterThan(1); // parallel
    expect(maxInFlight).toBeLessThanOrEqual(4); // bounded
  });

  it("refreshes legacy provider_connections only when no account doc covered that uid/provider", async () => {
    const db = new FakeSweepDb();
    seedAccount(db, "u1", "a1", { providerID: "codex", lastRefreshAt: "2026-06-01T00:00:00.000Z" });
    db.store.set(connectionPath("u1", "codex"), { status: "connected", lastRefreshAt: "2026-06-01T00:00:00.000Z" });
    db.store.set(connectionPath("u2", "kimi"), { status: "connected", lastRefreshAt: "2026-06-01T00:00:00.000Z" });

    const calls: SweepCalls = { refreshedAccounts: [], refreshedLegacy: [] };
    await runQuotaRefreshSweep(asSweepDb(db), sweepOptions(db, calls));

    expect(calls.refreshedAccounts).toEqual([accountPath("u1", "a1")]);
    expect(calls.refreshedLegacy).toEqual([connectionPath("u2", "kimi")]);
  });

  it("a throwing refresher does not starve the rest of the batch", async () => {
    const db = new FakeSweepDb();
    seedAccount(db, "u1", "a1", { lastRefreshAt: "2026-06-01T00:00:00.000Z" });
    seedAccount(db, "u2", "a2", { lastRefreshAt: "2026-06-02T00:00:00.000Z" });
    seedAccount(db, "u3", "a3", { lastRefreshAt: "2026-06-03T00:00:00.000Z" });

    const calls: SweepCalls = { refreshedAccounts: [], refreshedLegacy: [] };
    const options = {
      ...sweepOptions(db, calls),
      refreshAccountDoc: async (doc: FakeSweepDoc) => {
        if (doc.path === accountPath("u2", "a2")) throw new Error("provider exploded");
        calls.refreshedAccounts.push(doc.path);
      },
    };

    await expect(runQuotaRefreshSweep(asSweepDb(db), options)).rejects.toThrow("provider exploded");
    expect(calls.refreshedAccounts).toEqual([accountPath("u1", "a1"), accountPath("u3", "a3")]);
  });
});

describe("mapWithConcurrency", () => {
  it("processes every item exactly once with the requested width", async () => {
    const seen: number[] = [];
    let inFlight = 0;
    let maxInFlight = 0;
    await mapWithConcurrency([1, 2, 3, 4, 5, 6, 7], 3, async (item) => {
      inFlight += 1;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((resolve) => setTimeout(resolve, 2));
      seen.push(item);
      inFlight -= 1;
    });
    expect([...seen].sort((a: number, b: number) => a - b)).toEqual([1, 2, 3, 4, 5, 6, 7]);
    expect(maxInFlight).toBeLessThanOrEqual(3);
  });

  it("finishes remaining items even when one rejects, then surfaces the error", async () => {
    const seen: number[] = [];
    await expect(
      mapWithConcurrency([1, 2, 3, 4], 2, async (item) => {
        if (item === 2) throw new Error("boom");
        seen.push(item);
      }),
    ).rejects.toThrow("boom");
    expect([...seen].sort((a: number, b: number) => a - b)).toEqual([1, 3, 4]);
  });
});
