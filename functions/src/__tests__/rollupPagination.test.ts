import { describe, expect, it } from "vitest";
import { forEachInPages } from "../rollupPagination.js";

class FakeDoc {
  constructor(readonly id: string) {}
  data() {
    return { id: this.id };
  }
}

/**
 * Minimal Firestore Query stand-in that supports the orderBy/limit/startAfter
 * cursor surface `forEachInPages` relies on. Tracks how many `.get()` calls the
 * helper made so we can assert it actually paged rather than reading all at once.
 */
class FakeQuery {
  getCalls = 0;
  constructor(
    private readonly docs: FakeDoc[],
    private readonly offset = 0,
    private readonly cap = Number.POSITIVE_INFINITY,
    private readonly stats = { getCalls: 0 },
  ) {}

  orderBy(): FakeQuery {
    return new FakeQuery(this.docs, this.offset, this.cap, this.stats);
  }

  startAfter(cursor: FakeDoc): FakeQuery {
    const idx = this.docs.findIndex((d) => d.id === cursor.id);
    return new FakeQuery(this.docs, idx + 1, this.cap, this.stats);
  }

  limit(n: number): FakeQuery {
    return new FakeQuery(this.docs, this.offset, n, this.stats);
  }

  async get() {
    this.stats.getCalls += 1;
    const slice = this.docs.slice(this.offset, this.offset + this.cap);
    return { empty: slice.length === 0, size: slice.length, docs: slice };
  }
}

function query(ids: string[]) {
  const stats = { getCalls: 0 };
  const q = new FakeQuery(
    ids.map((id) => new FakeDoc(id)),
    0,
    Number.POSITIVE_INFINITY,
    stats,
  );
  return { q, stats };
}

describe("forEachInPages", () => {
  it("streams every document in order across pages", async () => {
    const { q } = query(["a", "b", "c", "d", "e"]);
    const seen: string[] = [];
    const total = await forEachInPages(
      q,
      "startedAt",
      (doc) => {
        seen.push(doc.id);
      },
      2,
    );
    expect(seen).toEqual(["a", "b", "c", "d", "e"]);
    expect(total).toBe(5);
  });

  it("pages rather than reading the whole result set at once", async () => {
    const { q, stats } = query(["a", "b", "c", "d", "e"]);
    await forEachInPages(q, "startedAt", () => {}, 2);
    // 3 full pages (2,2,1); the last short page ends the loop without an extra read.
    expect(stats.getCalls).toBe(3);
  });

  it("stops after an empty trailing page when the count is an exact multiple", async () => {
    const { q, stats } = query(["a", "b", "c", "d"]);
    const total = await forEachInPages(q, "startedAt", () => {}, 2);
    expect(total).toBe(4);
    // pages (2,2) then one empty read to detect the end.
    expect(stats.getCalls).toBe(3);
  });

  it("handles an empty range without invoking the callback", async () => {
    const { q, stats } = query([]);
    let calls = 0;
    const total = await forEachInPages(
      q,
      "startedAt",
      () => {
        calls += 1;
      },
      2,
    );
    expect(total).toBe(0);
    expect(calls).toBe(0);
    expect(stats.getCalls).toBe(1);
  });
});
