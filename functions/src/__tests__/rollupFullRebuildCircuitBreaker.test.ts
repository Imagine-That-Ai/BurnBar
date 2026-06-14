/**
 * Full-rebuild circuit breaker lifecycle (P0-7).
 *
 * The destructive repair path (recursiveDelete of four counter collections +
 * full raw-usage rescan) used to account for failures only in an in-process
 * catch handler, so a timeout/OOM-killed invocation never advanced
 * `consecutiveFullRebuildFailures`: the worker re-deleted and re-died every
 * 5 minutes forever, and the client callable bypassed the breaker entirely.
 * These tests pin the whole gate lifecycle against an in-memory Firestore
 * (the patterns of rollupRebuildSkip.test.ts / rollupPendingDeltaQueue.test.ts):
 *
 *  - the breaker opens after N consecutive full-rebuild failures;
 *  - full rebuilds are refused while it is open (no destructive work);
 *  - a successful rebuild clears failure/breaker/marker state;
 *  - the PRE-SCAN attempt marker turns a simulated kill into a counted
 *    failure on the next pass, with no catch handler ever running;
 *  - the callable path honors the breaker, the in-flight dedupe, and the
 *    per-user force cooldown;
 *  - a capped pending-delta drain leaves the job dirty for the next tick;
 *  - a 2,500-doc usage history pages through the rebuild at page size 500
 *    and converges exactly.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { FieldValue, type Firestore } from "firebase-admin/firestore";

const { logInfoMock, logErrorMock } = vi.hoisted(() => ({ logInfoMock: vi.fn(), logErrorMock: vi.fn() }));
vi.mock("../logging.js", async () => {
  const actual = await vi.importActual<typeof import("../logging.js")>("../logging.js");
  return { ...actual, logInfo: logInfoMock, logError: logErrorMock };
});

import {
  beginFullRebuildAttempt,
  buildPendingCounterDelta,
  computeUserRollupsFromCounters,
  drainPendingCounterDeltas,
  FULL_REBUILD_ATTEMPT_STALE_MS,
  rebuildUserRollupCounters,
  recordRollupRebuildFailure,
  refreshUserRollups,
  RollupRebuildUnavailableError,
} from "../rollups.js";
import type { UsageEventDoc } from "../types.js";

type Doc = Record<string, unknown>;

const DELETE = Symbol("firestore-delete");

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype;
}

/**
 * Mirrors Firestore set() semantics the production code relies on:
 * merge:false replaces the document, merge:true deep-merges plain maps, and
 * FieldValue sentinels apply against the existing value — increments carry an
 * `operand` (nested increments included, which the rolling all_time
 * dailyTokens map relies on); every other sentinel is a delete.
 */
function mergeValue(existing: unknown, value: unknown, merge: boolean): unknown {
  if (value instanceof FieldValue) {
    const operand = Object.getOwnPropertyDescriptor(value, "operand")?.value;
    if (typeof operand === "number") {
      return (typeof existing === "number" ? existing : 0) + operand;
    }
    return DELETE;
  }
  if (isPlainObject(value)) {
    const base: Doc = merge && isPlainObject(existing) ? { ...existing } : {};
    for (const [key, entry] of Object.entries(value)) {
      const next = mergeValue(base[key], entry, merge);
      if (next === DELETE) delete base[key];
      else base[key] = next;
    }
    return base;
  }
  return value;
}

class FakeDocRef {
  constructor(
    private readonly fake: FakeFirestore,
    readonly path: string,
  ) {}

  get id(): string {
    return this.path.split("/").at(-1) ?? "";
  }

  async get() {
    const data = this.fake.store.get(this.path);
    return {
      exists: data !== undefined,
      data: () => (data === undefined ? undefined : { ...data }),
    };
  }

  set(data: Doc, options?: { merge?: boolean }) {
    const merge = options?.merge === true;
    const next: Doc = merge ? { ...(this.fake.store.get(this.path) ?? {}) } : {};
    for (const [key, value] of Object.entries(data)) {
      const merged = mergeValue(next[key], value, merge);
      if (merged === DELETE) delete next[key];
      else next[key] = merged;
    }
    this.fake.store.set(this.path, next);
    return Promise.resolve();
  }

  delete() {
    this.fake.store.delete(this.path);
    return Promise.resolve();
  }

  collection(name: string) {
    return new FakeCollectionRef(this.fake, `${this.path}/${name}`);
  }
}

class FakeCollectionRef {
  constructor(
    private readonly fake: FakeFirestore,
    readonly path: string,
    private readonly limitCount?: number,
    private readonly startAfterId?: string,
  ) {}

  doc(id: string) {
    return new FakeDocRef(this.fake, `${this.path}/${id}`);
  }

  // documentId range filters are irrelevant to the fixtures; the production
  // code re-filters hits against its day-id set anyway.
  where() {
    return this;
  }

  orderBy() {
    return this;
  }

  limit(count: number) {
    return new FakeCollectionRef(this.fake, this.path, count, this.startAfterId);
  }

  startAfter(doc: { id: string }) {
    return new FakeCollectionRef(this.fake, this.path, this.limitCount, doc.id);
  }

  async get() {
    this.fake.collectionGets.push(this.path);
    const prefix = `${this.path}/`;
    const docs = [...this.fake.store.keys()]
      .filter((path) => path.startsWith(prefix) && !path.slice(prefix.length).includes("/"))
      .map((path) => ({ id: path.slice(prefix.length), path }))
      .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
      .filter((entry) => !this.startAfterId || entry.id > this.startAfterId)
      .slice(0, this.limitCount)
      .map((entry) => ({
        id: entry.id,
        ref: new FakeDocRef(this.fake, entry.path),
        data: () => ({ ...(this.fake.store.get(entry.path) ?? {}) }),
      }));
    return { empty: docs.length === 0, docs };
  }
}

class FakeFirestore {
  readonly store = new Map<string, Doc>();
  readonly collectionGets: string[] = [];
  readonly recursiveDeletes: string[] = [];
  /** Simulates an infrastructure outage inside the destructive repair path. */
  failRecursiveDelete = false;

  doc(path: string) {
    return new FakeDocRef(this, path);
  }

  collection(path: string) {
    return new FakeCollectionRef(this, path);
  }

  recursiveDelete(collection: FakeCollectionRef) {
    if (this.failRecursiveDelete) {
      return Promise.reject(new Error("simulated recursiveDelete outage"));
    }
    this.recursiveDeletes.push(collection.path);
    const prefix = `${collection.path}/`;
    for (const path of [...this.store.keys()]) {
      if (path.startsWith(prefix)) this.store.delete(path);
    }
    return Promise.resolve();
  }

  batch() {
    const ops: Array<() => Promise<void>> = [];
    return {
      set: (ref: FakeDocRef, data: Doc, options?: { merge?: boolean }) => {
        ops.push(() => ref.set(data, options));
      },
      commit: async () => {
        for (const op of ops) await op();
      },
    };
  }

  async runTransaction<T>(
    fn: (transaction: {
      get: (ref: FakeDocRef) => ReturnType<FakeDocRef["get"]>;
      getAll: (...refs: FakeDocRef[]) => Promise<Awaited<ReturnType<FakeDocRef["get"]>>[]>;
      set: (ref: FakeDocRef, data: Doc, options?: { merge?: boolean }) => void;
      delete: (ref: FakeDocRef) => void;
    }) => Promise<T>,
  ): Promise<T> {
    return fn({
      get: (ref) => ref.get(),
      getAll: (...refs) => Promise.all(refs.map((ref) => ref.get())),
      set: (ref, data, options) => {
        void ref.set(data, options);
      },
      delete: (ref) => {
        void ref.delete();
      },
    });
  }

  asFirestore(): Firestore {
    // The engine takes the nominal admin `Firestore` class, which a
    // structural in-memory fake can never satisfy.
    // @ts-expect-error in-memory fake is structurally sufficient for rollup tests
    return this;
  }
}

const UID = "u-breaker";
const JOB_PATH = `users/${UID}/rollup_jobs/current`;
const QUEUE_PATH = `users/${UID}/pending_counter_deltas`;
const T0 = "2026-06-09T00:00:00.000Z";
const NOW_ISO = new Date().toISOString();
/** maxConsecutiveFullRebuildFailures: 3, breaker pause: 60 minutes. */
const GATE = { maxConsecutiveFullRebuildFailures: 3, circuitBreakerMinutes: 60 };
const STALE_MARKER = new Date(Date.now() - FULL_REBUILD_ATTEMPT_STALE_MS - 60_000).toISOString();
const FRESH_MARKER = new Date(Date.now() - 60_000).toISOString();

function usageEvent(sessionId: string, tokens = 10): UsageEventDoc {
  return {
    provider: "codex",
    providerID: "codex",
    schemaVersion: 1,
    sessionId,
    model: "gpt-5.5",
    inputTokens: tokens,
    outputTokens: 0,
    totalTokens: tokens,
    cost: 0.001,
    recordedAt: NOW_ISO,
    startTime: NOW_ISO,
  };
}

function seedUsage(fake: FakeFirestore, count: number): void {
  for (let i = 0; i < count; i += 1) {
    const id = String(i).padStart(6, "0");
    fake.store.set(`users/${UID}/usage/${id}`, { ...usageEvent(`session-${id}`) });
  }
}

function seedQueue(fake: FakeFirestore, count: number): void {
  for (let i = 0; i < count; i += 1) {
    const id = String(i).padStart(6, "0");
    const delta = buildPendingCounterDelta(`usage-${id}`, undefined, usageEvent(`queued-${id}`), NOW_ISO);
    if (!delta) throw new Error(`expected a pending delta for usage-${id}`);
    fake.store.set(`${QUEUE_PATH}/${id}`, delta);
  }
}

function queueSize(fake: FakeFirestore): number {
  return [...fake.store.keys()].filter((path) => path.startsWith(`${QUEUE_PATH}/`)).length;
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("circuit breaker opening on consecutive failures", () => {
  it("opens after the configured number of consecutive full-rebuild failures", async () => {
    const fake = new FakeFirestore();
    // lastErrorCode marks the previous pass as a full-rebuild context, so
    // each recorded failure advances the consecutive counter.
    fake.store.set(JOB_PATH, { dirty: true, lastErrorCode: "seed failure" });

    const first = await recordRollupRebuildFailure(fake.asFirestore(), UID, "boom 1", GATE);
    expect(first.breakerOpened).toBe(false);
    const second = await recordRollupRebuildFailure(fake.asFirestore(), UID, "boom 2", GATE);
    expect(second.breakerOpened).toBe(false);
    const third = await recordRollupRebuildFailure(fake.asFirestore(), UID, "boom 3", GATE);
    expect(third.breakerOpened).toBe(true);

    const job = fake.store.get(JOB_PATH);
    expect(job?.consecutiveFullRebuildFailures).toBe(3);
    expect(job?.lastErrorCode).toBe("boom 3");
    expect(Date.parse(String(job?.fullRebuildCircuitOpenUntil))).toBeGreaterThan(Date.now());
  });

  it("a first failure on a healthy job records the error code without advancing the counter", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: true, dirtiedAt: T0 });

    const result = await recordRollupRebuildFailure(fake.asFirestore(), UID, "delta drain failed", GATE);

    expect(result.breakerOpened).toBe(false);
    const job = fake.store.get(JOB_PATH);
    expect(job?.lastErrorCode).toBe("delta drain failed");
    expect(job?.consecutiveFullRebuildFailures).toBeUndefined();
  });
});

describe("breaker enforcement (worker and callable share the gate)", () => {
  it("refuses the full rebuild while the breaker is open — no destructive work happens", async () => {
    const fake = new FakeFirestore();
    const openUntil = new Date(Date.now() + 30 * 60 * 1000).toISOString();
    fake.store.set(JOB_PATH, {
      dirty: true,
      dirtiedAt: T0,
      lastErrorCode: "x",
      fullRebuildCircuitOpenUntil: openUntil,
    });

    const error = await refreshUserRollups(fake.asFirestore(), UID).then(
      () => undefined,
      (err: unknown) => err,
    );
    expect(error).toBeInstanceOf(RollupRebuildUnavailableError);
    expect(error).toMatchObject({ reason: "circuit_open", retryAt: openUntil });

    // The scheduled worker's gate sees the same refusal.
    await expect(beginFullRebuildAttempt(fake.asFirestore(), UID, GATE)).resolves.toEqual({
      status: "circuit_open",
      openUntil,
    });
    expect(fake.recursiveDeletes).toEqual([]);
  });

  it("an expired breaker lets the rebuild through and a success clears all failure state", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, {
      dirty: true,
      dirtiedAt: T0,
      lastErrorCode: "x",
      consecutiveFullRebuildFailures: 2,
      fullRebuildCircuitOpenUntil: new Date(Date.now() - 60_000).toISOString(),
    });
    seedUsage(fake, 3);

    const { rebuiltCounters } = await refreshUserRollups(fake.asFirestore(), UID);

    expect(rebuiltCounters).toBe(true);
    const job = fake.store.get(JOB_PATH);
    expect(job?.dirty).toBe(false);
    expect(job?.lastErrorCode).toBeUndefined();
    expect(job?.consecutiveFullRebuildFailures).toBeUndefined();
    expect(job?.fullRebuildCircuitOpenUntil).toBeUndefined();
    expect(job?.fullRebuildAttemptInFlightAt).toBeUndefined();
  });
});

describe("pre-scan attempt marker (simulated kill accounting)", () => {
  it("counts a stale in-flight marker as a consecutive failure before the next attempt starts", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, {
      dirty: true,
      lastErrorCode: "x",
      consecutiveFullRebuildFailures: 1,
      fullRebuildAttemptInFlightAt: STALE_MARKER,
    });

    const gate = await beginFullRebuildAttempt(fake.asFirestore(), UID, GATE);

    expect(gate).toEqual({ status: "started", countedStaleAttempt: true });
    const job = fake.store.get(JOB_PATH);
    expect(job?.consecutiveFullRebuildFailures).toBe(2);
    // The marker is re-stamped for the NEW attempt this gate just claimed.
    expect(Date.parse(String(job?.fullRebuildAttemptInFlightAt))).toBeGreaterThan(Date.now() - 5_000);
  });

  it("a stale marker reaching the ceiling opens the breaker with no catch handler ever running", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, {
      dirty: true,
      lastErrorCode: "x",
      consecutiveFullRebuildFailures: 2,
      fullRebuildAttemptInFlightAt: STALE_MARKER,
    });

    const gate = await beginFullRebuildAttempt(fake.asFirestore(), UID, GATE);

    expect(gate.status).toBe("circuit_open");
    const job = fake.store.get(JOB_PATH);
    expect(job?.consecutiveFullRebuildFailures).toBe(3);
    expect(job?.fullRebuildAttemptInFlightAt).toBeUndefined();
    expect(Date.parse(String(job?.fullRebuildCircuitOpenUntil))).toBeGreaterThan(Date.now());
  });

  it("a kill on a previously healthy job records the synthetic error code so repair re-routes", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: false, fullRebuildAttemptInFlightAt: STALE_MARKER });

    const gate = await beginFullRebuildAttempt(fake.asFirestore(), UID, GATE);

    expect(gate).toEqual({ status: "started", countedStaleAttempt: true });
    // The killed attempt may have deleted the counters before dying, so they
    // must stay marked untrusted (routes the next pass through repair).
    expect(fake.store.get(JOB_PATH)?.lastErrorCode).toBe("full_rebuild_attempt_killed");
  });

  it("a fresh in-flight marker dedupes concurrent rebuilds (worker gate and callable alike)", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: true, lastErrorCode: "x", fullRebuildAttemptInFlightAt: FRESH_MARKER });

    await expect(beginFullRebuildAttempt(fake.asFirestore(), UID, GATE)).resolves.toEqual({
      status: "in_flight",
      attemptStartedAt: FRESH_MARKER,
    });
    await expect(refreshUserRollups(fake.asFirestore(), UID, { force: true })).rejects.toMatchObject({
      reason: "in_flight",
    });
    expect(fake.recursiveDeletes).toEqual([]);
    // The dedupe did not consume a failure: the counter is untouched.
    expect(fake.store.get(JOB_PATH)?.consecutiveFullRebuildFailures).toBeUndefined();
  });

  it("keeps the gate-created job doc for a brand-new user parseable so the marker stays visible", async () => {
    const fake = new FakeFirestore();

    const first = await beginFullRebuildAttempt(fake.asFirestore(), UID, GATE);
    expect(first.status).toBe("started");

    // Regression: the gate-created doc must carry a boolean `dirty`, or
    // parseRollupJobDoc rejects it and this second claim would also report
    // "started" — no in-flight dedupe and an uncountable kill.
    const second = await beginFullRebuildAttempt(fake.asFirestore(), UID, GATE);
    expect(second.status).toBe("in_flight");
  });

  it("an in-process rebuild failure records the failure and frees the marker immediately", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: false, dirtiedAt: T0 });
    fake.failRecursiveDelete = true;

    await expect(refreshUserRollups(fake.asFirestore(), UID, { force: true })).rejects.toThrow(
      "simulated recursiveDelete outage",
    );

    const job = fake.store.get(JOB_PATH);
    expect(String(job?.lastErrorCode)).toContain("simulated recursiveDelete outage");
    // No dangling marker: retries are not refused as in_flight for the whole
    // staleness window, and the failure was counted NOW, not at staleness.
    expect(job?.fullRebuildAttemptInFlightAt).toBeUndefined();

    fake.failRecursiveDelete = false;
    const gate = await beginFullRebuildAttempt(fake.asFirestore(), UID, GATE);
    expect(gate.status).toBe("started");
  });
});

describe("client force-rebuild cooldown (rebuildUsageRollups callable path)", () => {
  it("rate-limits force rebuilds per user from the cooldown anchor stamped at attempt start", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: false, dirtiedAt: T0 });
    seedUsage(fake, 2);

    await refreshUserRollups(fake.asFirestore(), UID, { force: true });
    const stampedAt = Date.parse(String(fake.store.get(JOB_PATH)?.lastForceRebuildAt));
    expect(Number.isFinite(stampedAt)).toBe(true);
    // One full rebuild ran: all four counter collections were purged once.
    expect(fake.recursiveDeletes).toHaveLength(4);

    // Default cooldown knob: rollupForceRebuildMinIntervalMinutes = 10.
    await expect(refreshUserRollups(fake.asFirestore(), UID, { force: true })).rejects.toMatchObject({
      reason: "force_cooldown",
      retryAt: new Date(stampedAt + 10 * 60 * 1000).toISOString(),
    });
    expect(fake.recursiveDeletes).toHaveLength(4);
  });

  it("the worker's non-force repair path ignores the force cooldown", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, {
      dirty: true,
      dirtiedAt: T0,
      lastErrorCode: "x",
      lastForceRebuildAt: new Date().toISOString(),
    });
    seedUsage(fake, 1);

    const { rebuiltCounters } = await refreshUserRollups(fake.asFirestore(), UID);

    expect(rebuiltCounters).toBe(true);
    expect(fake.store.get(JOB_PATH)?.lastErrorCode).toBeUndefined();
  });
});

describe("pending-delta drain page cap", () => {
  it("caps the drain at maxPages, reports it, and emits the alertable log event", async () => {
    const fake = new FakeFirestore();
    seedQueue(fake, 250);

    const result = await drainPendingCounterDeltas(fake.asFirestore(), UID, { maxPages: 2 });

    expect(result).toEqual({ drainedDocs: 200, pages: 2, capped: true });
    expect(queueSize(fake)).toBe(50);
    // Alert policies key on exactly this jsonPayload.event string.
    expect(logInfoMock).toHaveBeenCalledWith(
      expect.objectContaining({ event: "rollup.delta_drain_capped", uid: UID, pages: 2, max_pages: 2 }),
    );
  });

  it("a drain that finishes under the cap is not reported as capped", async () => {
    const fake = new FakeFirestore();
    seedQueue(fake, 150);

    const result = await drainPendingCounterDeltas(fake.asFirestore(), UID, { maxPages: 2 });

    expect(result).toEqual({ drainedDocs: 150, pages: 2, capped: false });
    expect(queueSize(fake)).toBe(0);
    expect(logInfoMock).not.toHaveBeenCalledWith(expect.objectContaining({ event: "rollup.delta_drain_capped" }));
  });

  it("a capped drain leaves the rollup job dirty so the next tick resumes the queue", async () => {
    const fake = new FakeFirestore();
    fake.store.set(JOB_PATH, { dirty: true, dirtiedAt: T0 });
    seedQueue(fake, 150);

    await refreshUserRollups(fake.asFirestore(), UID, { drainMaxPages: 1 });

    expect(fake.store.get(JOB_PATH)?.dirty).toBe(true);
    expect(queueSize(fake)).toBe(50);

    // The next pass finishes the remaining queue and clears dirty.
    await refreshUserRollups(fake.asFirestore(), UID);
    expect(fake.store.get(JOB_PATH)?.dirty).toBe(false);
    expect(queueSize(fake)).toBe(0);
    expect(fake.recursiveDeletes).toEqual([]);
  });
});

describe("full-history pagination (large account synthetic)", () => {
  it("replays a 2,500-doc usage history at repair page size 500: exactly 5 pages, exact convergence", async () => {
    const fake = new FakeFirestore();
    seedUsage(fake, 2_500);

    const result = await rebuildUserRollupCounters(fake.asFirestore(), UID, { pageSize: 500 });

    expect(result).toEqual({ usageDocsScanned: 2_500, pages: 5, winnersWritten: 2_500 });

    const rollups = await computeUserRollupsFromCounters(fake.asFirestore(), UID);
    expect(rollups.all_time.totals.requests).toBe(2_500);
    expect(rollups.all_time.totals.tokens).toBe(25_000);
    expect(rollups.today.totals.requests).toBe(2_500);
  });
});

describe("alertable structured log event keys", () => {
  // Another workstream wires GCP log-based alert policies to exactly these
  // jsonPayload.event strings. This pins the literals at the source level so
  // a rename cannot slip through while the alerts silently go dark.
  it("keeps the exact jsonPayload.event strings the alert policies key on", () => {
    const read = (relative: string) => readFileSync(resolve(__dirname, relative), "utf8");
    const scheduled = read("../scheduled.ts");
    const rollups = read("../rollups.ts");
    const misc = read("../callables/misc.ts");

    expect(scheduled).toContain('event: "rollup.full_rebuild_circuit_open"');
    expect(scheduled).toContain('event: "rollup.rebuild_failed"');
    expect(rollups).toContain('event: "rollup.delta_drain_capped"');
    expect(misc).toContain('event: "rollup.full_rebuild_circuit_open"');
  });
});
