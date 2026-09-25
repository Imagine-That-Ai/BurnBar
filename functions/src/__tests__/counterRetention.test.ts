/**
 * Day-bucket retention sweeper (Wave 2.6).
 *
 * Pins the cutoff (day < today - 180d, mirroring Swift
 * `UsageRetentionPolicy`), the `recursiveDelete` semantics (day doc AND its
 * per-day subcollections die together — a plain delete would orphan them
 * exactly like the TTL backstop), and the bounded paging (`hasMore` when the
 * per-tick budget exhausts). The fake implements only the collectionGroup +
 * recursiveDelete surface the sweeper touches.
 */
import { describe, expect, it } from "vitest";
import type { Firestore } from "firebase-admin/firestore";

import { COUNTER_DAY_RETENTION_DAYS } from "../rollupCounters.js";
import { counterDayCutoff, reapExpiredCounterDays } from "../domains/scheduled/reapExpiredCounterDays.js";

type Doc = Record<string, unknown>;

const UID = "u-sweep";

function dayPath(day: string): string {
  return `users/${UID}/usage_counter_days/${day}`;
}

class FakeDocRef {
  constructor(
    private readonly fake: FakeFirestore,
    readonly path: string,
  ) {}

  get id(): string {
    return this.path.split("/").at(-1) ?? "";
  }
}

class FakeFirestore {
  readonly store = new Map<string, Doc>();

  doc(path: string): FakeDocRef {
    return new FakeDocRef(this, path);
  }

  collectionGroup(name: string) {
    const { store } = this;
    const docRef = (path: string): FakeDocRef => this.doc(path);
    return {
      where(_field: string, _op: string, _value: unknown) {
        void _field;
        void _op;
        void _value;
        const clauses: { field: string; op: string; value: unknown }[] = [
          { field: _field, op: _op, value: _value },
        ];
        const startAfterIds: string[] = [];
        let limitCount: number | undefined;
        const api = {
          where(field: string, op: string, value: unknown) {
            clauses.push({ field, op, value });
            return api;
          },
          startAfter(doc: FakeDocRef) {
            startAfterIds.push(doc.id);
            return api;
          },
          limit(count: number) {
            limitCount = count;
            return api;
          },
          async get() {
            const docs = [...store.entries()]
              .filter(([path]) => {
                const segments = path.split("/");
                // users/{uid}/usage_counter_days/{day}: collection docs only.
                return (
                  segments.length === 4 &&
                  segments[0] === "users" &&
                  segments[2] === name
                );
              })
              .filter(([, data]) =>
                clauses.every(({ field, op, value }) => {
                  const actual = data[field];
                  if (op === "<") return typeof actual === "string" && typeof value === "string" && actual < value;
                  throw new Error(`unsupported op ${op}`);
                }),
              )
              .map(([path]) => path)
              .sort()
              .filter((path) => startAfterIds.every((id) => path.split("/").at(-1)! > id))
              .slice(0, limitCount)
              .map((path) => ({ id: path.split("/").at(-1)!, ref: docRef(path) }));
            return { empty: docs.length === 0, docs };
          },
        };
        return api;
      },
    };
  }

  async recursiveDelete(ref: FakeDocRef): Promise<void> {
    this.store.delete(ref.path);
    const prefix = `${ref.path}/`;
    for (const path of [...this.store.keys()]) {
      if (path.startsWith(prefix)) this.store.delete(path);
    }
  }

  asFirestore(): Firestore {
    return this as unknown as Firestore;
  }
}

const NOW_MS = Date.parse("2026-09-24T12:00:00.000Z");

describe("counter day retention", () => {
  it("cuts off at today minus the 180-day usage retention", () => {
    expect(COUNTER_DAY_RETENTION_DAYS).toBe(180);
    expect(counterDayCutoff(NOW_MS)).toBe("2026-03-28");
  });

  it("reaps expired day docs with their subcollections and keeps live days", async () => {
    const fake = new FakeFirestore();
    const expired = "2026-03-27";
    const live = "2026-03-28";
    fake.store.set(dayPath(expired), { day: expired, tokens: 10 });
    fake.store.set(`${dayPath(expired)}/providers/codex`, { tokens: 10 });
    fake.store.set(`${dayPath(expired)}/accounts/a`, { tokens: 10 });
    fake.store.set(dayPath(live), { day: live, tokens: 20 });
    fake.store.set(`${dayPath(live)}/providers/codex`, { tokens: 20 });

    const result = await reapExpiredCounterDays(fake.asFirestore(), { nowMs: NOW_MS });

    expect(result).toEqual({ reaped: 1, hasMore: false });
    // Day doc AND subcollections are gone (recursiveDelete, not a shell delete).
    expect(fake.store.has(dayPath(expired))).toBe(false);
    expect(fake.store.has(`${dayPath(expired)}/providers/codex`)).toBe(false);
    expect(fake.store.has(`${dayPath(expired)}/accounts/a`)).toBe(false);
    // Cutoff day and its subtree survive.
    expect(fake.store.get(dayPath(live))?.tokens).toBe(20);
    expect(fake.store.has(`${dayPath(live)}/providers/codex`)).toBe(true);
  });

  it("reports hasMore when the per-tick budget exhausts", async () => {
    const fake = new FakeFirestore();
    for (let i = 1; i <= 5; i++) {
      const day = `2026-01-0${i}`;
      fake.store.set(dayPath(day), { day, tokens: 1 });
    }

    const first = await reapExpiredCounterDays(fake.asFirestore(), {
      nowMs: NOW_MS,
      batchSize: 2,
      maxBatches: 1,
    });
    expect(first).toEqual({ reaped: 2, hasMore: true });

    const rest = await reapExpiredCounterDays(fake.asFirestore(), { nowMs: NOW_MS });
    expect(rest).toEqual({ reaped: 3, hasMore: false });
  });
});
