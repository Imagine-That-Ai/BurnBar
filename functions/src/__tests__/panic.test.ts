import { describe, expect, it } from "vitest";
import { __testing__ } from "../callables/panic.js";

const { drainCollection, PAGE_LIMIT } = __testing__;

interface StubDoc {
  id: string;
}
interface StubQuery {
  orderBy: () => StubQuery;
  limit: (n: number) => StubQuery;
  startAfter: (doc: StubDoc) => StubQuery;
  get: () => Promise<{ empty: boolean; size: number; docs: StubDoc[] }>;
}

/** Minimal Firestore Query stub over a sorted in-memory doc array (id-ordered pagination). */
function stubQuery(allDocs: StubDoc[]): StubQuery {
  const make = (afterId: string | undefined, lim: number | undefined): StubQuery => ({
    orderBy: () => make(afterId, lim),
    limit: (n: number) => make(afterId, n),
    startAfter: (doc: StubDoc) => make(doc.id, lim),
    get: async () => {
      let pool = allDocs;
      if (afterId) {
        const idx = pool.findIndex((d) => d.id === afterId);
        pool = pool.slice(idx + 1);
      }
      const page = pool.slice(0, lim ?? pool.length);
      return { empty: page.length === 0, size: page.length, docs: page };
    },
  });
  return make(undefined, undefined);
}

function docs(n: number): StubDoc[] {
  // zero-padded ids so string order == numeric order (matches FieldPath.documentId ordering)
  return Array.from({ length: n }, (_, i) => ({ id: String(i).padStart(6, "0") }));
}

// drainCollection takes a FirebaseFirestore.Query; the stub satisfies the slice we use.
const asQuery = (q: StubQuery) => q as unknown as FirebaseFirestore.Query;

describe("panic drainCollection — completeness (the >500 fix)", () => {
  it("visits EVERY document across multiple pages (not just the first page)", async () => {
    const all = docs(950); // > 2 * PAGE_LIMIT
    const seen = new Set<string>();
    const total = await drainCollection(asQuery(stubQuery(all)), async (page) => {
      for (const d of page) seen.add(d.id);
      return page.length;
    });
    expect(total).toBe(950);
    expect(seen.size).toBe(950); // no document is skipped or double-counted
    expect(PAGE_LIMIT).toBeLessThan(500); // each batch stays under Firestore's 500-op limit
  });

  it("handles an exactly-full final page boundary", async () => {
    const all = docs(PAGE_LIMIT * 2); // last page is exactly full, then an empty page ends it
    let pages = 0;
    const total = await drainCollection(asQuery(stubQuery(all)), async (page) => {
      pages += 1;
      return page.length;
    });
    expect(total).toBe(PAGE_LIMIT * 2);
    expect(pages).toBe(2);
  });

  it("returns 0 for an empty collection without iterating", async () => {
    let called = false;
    const total = await drainCollection(asQuery(stubQuery([])), async () => {
      called = true;
      return 0;
    });
    expect(total).toBe(0);
    expect(called).toBe(false);
  });

  it("counts only what handlePage reports (skipped docs don't inflate the total)", async () => {
    const all = docs(10);
    const total = await drainCollection(
      asQuery(stubQuery(all)),
      async (page) => page.filter((_, i) => i % 2 === 0).length,
    );
    expect(total).toBe(5);
  });
});
