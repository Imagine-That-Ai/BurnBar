/**
 * Execution-source (agent harness) and harness×model combo aggregation in the
 * usage rollup pipeline.
 *
 * Covers the new counter contribution fields (`usageContribution`), the two
 * rollup aggregators (`aggregateExecutionSourceSummaries`,
 * `aggregateComboSummaries`), and the end-to-end counter -> rollup path that
 * puts both summaries on every window doc (`buildWindowRollupDoc`, exercised
 * through `computeUserRollupsFromCounters`). The in-memory Firestore mirrors
 * the fake in rollupRefactor.char.test.ts (same set() merge /
 * FieldValue.increment semantics).
 */
import { describe, expect, it } from "vitest";
import { FieldValue, type Firestore } from "firebase-admin/firestore";

import { usageContribution } from "../rollupCounters.js";
import {
  aggregateComboSummaries,
  aggregateExecutionSourceSummaries,
  computeUserRollupsFromCounters,
  rebuildUserRollupCounters,
} from "../rollupCompute.js";
import type { UsageEventDoc } from "../types.js";

type Doc = Record<string, unknown>;

const DELETE = Symbol("firestore-delete");

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && Object.getPrototypeOf(value) === Object.prototype;
}

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
    return { exists: data !== undefined, data: () => (data === undefined ? undefined : { ...data }) };
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

  doc(path: string) {
    return new FakeDocRef(this, path);
  }

  collection(path: string) {
    return new FakeCollectionRef(this, path);
  }

  recursiveDelete(collection: FakeCollectionRef) {
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
    // The engine takes the nominal admin Firestore class, while this test fake
    // is intentionally structural (same pattern as rollupRefactor.char.test.ts).
    return Object.create(this);
  }
}

const UID = "u-exec-source";
const T0 = "2026-06-09T00:00:00.000Z";
const NOW_ISO = new Date().toISOString();

function codexEvent(overrides: Partial<UsageEventDoc> = {}): UsageEventDoc {
  return {
    provider: "codex",
    providerID: "codex",
    schemaVersion: 1,
    sessionId: "codex-session-1",
    model: "gpt-5.5",
    inputTokens: 100,
    outputTokens: 25,
    totalTokens: 125,
    cost: 0.001,
    recordedAt: T0,
    startTime: T0,
    ...overrides,
  };
}

describe("usageContribution execution-source mapping", () => {
  it("passes executionSourceID and executionSourceName through verbatim when both exist", () => {
    const contribution = usageContribution(
      codexEvent({ executionSourceID: "claude-code", executionSourceName: "Claude Code" }),
    );

    expect(contribution?.executionSourceId).toBe("claude-code");
    expect(contribution?.executionSourceName).toBe("Claude Code");
  });

  it("derives a normalized id from the name when only executionSourceName exists", () => {
    const contribution = usageContribution(codexEvent({ executionSourceName: "Claude Code" }));

    expect(contribution?.executionSourceId).toBe("claude_code");
    expect(contribution?.executionSourceName).toBe("Claude Code");
  });

  it("falls back to the id as the display name when only executionSourceID exists", () => {
    const contribution = usageContribution(codexEvent({ executionSourceID: "cursor-cli" }));

    expect(contribution?.executionSourceId).toBe("cursor-cli");
    expect(contribution?.executionSourceName).toBe("cursor-cli");
  });

  it("leaves both fields undefined for legacy events with no execution source", () => {
    const contribution = usageContribution(codexEvent());

    expect(contribution?.executionSourceId).toBeUndefined();
    expect(contribution?.executionSourceName).toBeUndefined();
  });
});

describe("aggregateExecutionSourceSummaries", () => {
  it("groups by executionSourceId, sums metrics, and keeps the first non-empty name", () => {
    const summaries = aggregateExecutionSourceSummaries([
      { executionSourceId: "claude-code", executionSourceName: "", requests: 1, tokens: 10, costUsd: 0.125 },
      { executionSourceId: "claude-code", executionSourceName: "Claude Code", requests: 2, tokens: 20, costUsd: 0.25 },
      { executionSourceId: "codex", executionSourceName: "Codex", requests: 1, tokens: 5, costUsd: 0 },
    ]);

    expect(summaries).toHaveLength(2);
    const claude = summaries.find((s) => s.sourceId === "claude-code");
    expect(claude).toEqual({
      sourceId: "claude-code",
      sourceName: "Claude Code",
      totalRequests: 3,
      totalTokens: 30,
      totalCost: 0.375,
    });
  });

  it("skips docs without a string executionSourceId and drops all-zero entries", () => {
    const summaries = aggregateExecutionSourceSummaries([
      { executionSourceName: "No Id", requests: 5, tokens: 50, costUsd: 0.5 },
      { executionSourceId: 42, requests: 5, tokens: 50, costUsd: 0.5 },
      { executionSourceId: "zeroed", requests: 0, tokens: 0, costUsd: 0 },
      { executionSourceId: "codex", requests: 1, tokens: 5, costUsd: 0.125 },
    ]);

    expect(summaries).toEqual([
      { sourceId: "codex", sourceName: "", totalRequests: 1, totalTokens: 5, totalCost: 0.125 },
    ]);
  });

  it("sorts by totalTokens desc, then totalRequests desc", () => {
    const summaries = aggregateExecutionSourceSummaries([
      { executionSourceId: "low", requests: 9, tokens: 10, costUsd: 0 },
      { executionSourceId: "tie-fewer-requests", requests: 1, tokens: 20, costUsd: 0 },
      { executionSourceId: "tie-more-requests", requests: 3, tokens: 20, costUsd: 0 },
    ]);

    expect(summaries.map((s) => s.sourceId)).toEqual(["tie-more-requests", "tie-fewer-requests", "low"]);
  });
});

describe("aggregateComboSummaries", () => {
  it("groups by sourceId:provider:model and sums metrics", () => {
    const summaries = aggregateComboSummaries([
      {
        executionSourceId: "claude-code",
        executionSourceName: "Claude Code",
        provider: "codex",
        model: "gpt-5.5",
        requests: 1,
        tokens: 10,
        costUsd: 0.125,
      },
      {
        executionSourceId: "claude-code",
        executionSourceName: "Claude Code",
        provider: "codex",
        model: "gpt-5.5",
        requests: 2,
        tokens: 20,
        costUsd: 0.25,
      },
    ]);

    expect(summaries).toEqual([
      {
        sourceId: "claude-code",
        sourceName: "Claude Code",
        provider: "codex",
        model: "gpt-5.5",
        requests: 3,
        tokens: 30,
        cost: 0.375,
      },
    ]);
  });

  it("skips docs missing a source id, a model, or a parseable provider", () => {
    const summaries = aggregateComboSummaries([
      { executionSourceName: "No Id", provider: "codex", model: "gpt-5.5", requests: 1, tokens: 1, costUsd: 0 },
      { executionSourceId: "claude-code", provider: "codex", requests: 1, tokens: 1, costUsd: 0 },
      {
        executionSourceId: "claude-code",
        provider: "not-a-provider",
        model: "gpt-5.5",
        requests: 1,
        tokens: 1,
        costUsd: 0,
      },
      { executionSourceId: "claude-code", provider: "codex", model: "gpt-5.5", requests: 0, tokens: 0, costUsd: 0 },
      { executionSourceId: "codex", provider: "codex", model: "gpt-5.5", requests: 1, tokens: 5, costUsd: 0.125 },
    ]);

    expect(summaries).toHaveLength(1);
    expect(summaries[0].sourceId).toBe("codex");
  });

  it("sorts by tokens desc, then requests desc", () => {
    const summaries = aggregateComboSummaries([
      { executionSourceId: "a", provider: "codex", model: "m1", requests: 9, tokens: 10, costUsd: 0 },
      { executionSourceId: "b", provider: "codex", model: "m2", requests: 1, tokens: 20, costUsd: 0 },
      { executionSourceId: "c", provider: "codex", model: "m3", requests: 3, tokens: 20, costUsd: 0 },
    ]);

    expect(summaries.map((s) => s.sourceId)).toEqual(["c", "b", "a"]);
  });
});

describe("buildWindowRollupDoc execution-source summaries (via computeUserRollupsFromCounters)", () => {
  it("aggregates executionSources and combos counters onto every window doc", async () => {
    const fake = new FakeFirestore();
    for (let i = 0; i < 3; i += 1) {
      fake.store.set(`users/${UID}/usage/${String(i).padStart(6, "0")}`, {
        ...codexEvent({
          sessionId: `codex-session-${i}`,
          executionSourceID: "claude-code",
          executionSourceName: "Claude Code",
          cost: 0.125,
          recordedAt: NOW_ISO,
          startTime: NOW_ISO,
        }),
      });
    }
    // A legacy event with no execution source contributes to totals but to no
    // executionSource/combo doc.
    fake.store.set(`users/${UID}/usage/legacy`, {
      ...codexEvent({ sessionId: "codex-session-legacy", cost: 0.125, recordedAt: NOW_ISO, startTime: NOW_ISO }),
    });
    await rebuildUserRollupCounters(fake.asFirestore(), UID, { pageSize: 500 });

    const rollups = await computeUserRollupsFromCounters(fake.asFirestore(), UID);

    expect(rollups.all_time.totals.requests).toBe(4);
    expect(rollups.all_time.executionSourceSummaries).toEqual([
      { sourceId: "claude-code", sourceName: "Claude Code", totalRequests: 3, totalTokens: 375, totalCost: 0.375 },
    ]);
    expect(rollups.all_time.comboSummaries).toEqual([
      {
        sourceId: "claude-code",
        sourceName: "Claude Code",
        provider: "codex",
        model: "gpt-5.5",
        requests: 3,
        tokens: 375,
        cost: 0.375,
      },
    ]);
    // Same-day usage => the today window mirrors all_time.
    expect(rollups.today.executionSourceSummaries).toHaveLength(1);
    expect(rollups.today.comboSummaries).toHaveLength(1);
  });

  it("emits empty summaries when no counter docs carry execution sources", async () => {
    const fake = new FakeFirestore();
    fake.store.set(`users/${UID}/usage/000000`, { ...codexEvent() });
    await rebuildUserRollupCounters(fake.asFirestore(), UID, { pageSize: 500 });

    const rollups = await computeUserRollupsFromCounters(fake.asFirestore(), UID);

    for (const key of ["today", "7d", "30d", "90d", "all_time"] as const) {
      expect(rollups[key].executionSourceSummaries).toEqual([]);
      expect(rollups[key].comboSummaries).toEqual([]);
    }
  });
});
