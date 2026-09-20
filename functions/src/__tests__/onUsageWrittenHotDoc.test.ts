import { describe, expect, it } from "vitest";
import { FieldValue } from "firebase-admin/firestore";

import { applyUsageWrittenSideEffects } from "../triggers.js";
import { ROLLUP_DIRTY_COALESCE_MS } from "../rollupJobDirty.js";
import type { UsageEventDoc } from "../types.js";

type Doc = Record<string, unknown>;

class FakeDocRef {
  constructor(
    private readonly store: Map<string, Doc>,
    readonly path: string,
  ) {}

  async get() {
    const data = this.store.get(this.path);
    return {
      exists: data !== undefined,
      data: () => (data === undefined ? undefined : { ...data }),
    };
  }

  set(data: Doc, options?: { merge?: boolean }) {
    const next: Doc = options?.merge ? { ...(this.store.get(this.path) ?? {}) } : {};
    for (const [key, value] of Object.entries(data)) {
      if (value instanceof FieldValue) {
        delete next[key];
      } else {
        next[key] = value;
      }
    }
    this.store.set(this.path, next);
    return Promise.resolve();
  }
}

class FakeFirestore {
  readonly store = new Map<string, Doc>();
  jobWrites = 0;

  doc(path: string) {
    const ref = new FakeDocRef(this.store, path);
    if (path.endsWith("rollup_jobs/current")) {
      const originalSet = ref.set.bind(ref);
      ref.set = (data: Doc, options?: { merge?: boolean }) => {
        this.jobWrites += 1;
        return originalSet(data, options);
      };
    }
    return ref;
  }

  collection(path: string) {
    return {
      doc: (id: string) => this.doc(`${path}/${id}`),
    };
  }

  async runTransaction<T>(
    fn: (transaction: {
      get: (ref: FakeDocRef) => ReturnType<FakeDocRef["get"]>;
      set: (ref: FakeDocRef, data: Doc, options?: { merge?: boolean }) => void;
    }) => Promise<T>,
  ): Promise<T> {
    return fn({
      get: (ref) => ref.get(),
      set: (ref, data, options) => {
        void ref.set(data, options);
      },
    });
  }
}

const UID = "u-hot-doc";
const T0 = Date.parse("2026-09-14T00:00:00.000Z");

function eventDoc(index: number): UsageEventDoc {
  return {
    provider: "codex",
    providerID: "codex",
    schemaVersion: 1,
    sessionId: `burst-session-${index}`,
    model: "gpt-5.5",
    inputTokens: 10,
    outputTokens: 1,
    totalTokens: 11,
    cost: 0.001,
    recordedAt: new Date(T0).toISOString(),
    startTime: new Date(T0).toISOString(),
  };
}

describe("applyUsageWrittenSideEffects hot-doc coalescing", () => {
  it("does not write rollup_jobs/current once per event in a 400-event burst", async () => {
    const db = new FakeFirestore();
    const results: Array<"written" | "coalesced"> = [];
    for (let i = 0; i < 400; i += 1) {
      const result = await applyUsageWrittenSideEffects(
        db,
        UID,
        `usage-${i}`,
        undefined,
        eventDoc(i),
        T0 + i,
      );
      results.push(result);
    }
    expect(results.filter((row) => row === "written")).toHaveLength(1);
    expect(results.filter((row) => row === "coalesced")).toHaveLength(399);
    expect(db.jobWrites).toBe(1);
    expect(db.store.get(`users/${UID}/rollup_jobs/current`)).toMatchObject({ dirty: true });
  });

  it("refreshes dirtiedAt after the coalesce window so in-flight rebuilds cannot clear late events", async () => {
    const db = new FakeFirestore();
    await applyUsageWrittenSideEffects(db, UID, "usage-0", undefined, eventDoc(0), T0);
    const first = db.store.get(`users/${UID}/rollup_jobs/current`)?.dirtiedAt;
    await applyUsageWrittenSideEffects(
      db,
      UID,
      "usage-late",
      undefined,
      eventDoc(1),
      T0 + ROLLUP_DIRTY_COALESCE_MS + 1,
    );
    const second = db.store.get(`users/${UID}/rollup_jobs/current`)?.dirtiedAt;
    expect(second).not.toBe(first);
    expect(db.jobWrites).toBe(2);
  });
});
