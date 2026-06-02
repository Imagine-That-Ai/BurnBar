import { describe, expect, it } from "vitest";
import type { Firestore } from "firebase-admin/firestore";
import { revokeAllRemoteMcpGrantsForUser } from "../remoteMcpGrant.js";

interface FakeDoc {
  id: string;
  ref: { path: string };
  data: Record<string, unknown>;
  get(field: string): unknown;
}

function makeFakeFirestore(counts: { clients: number; grants: number; revokedEvery?: number }) {
  const collections = new Map<string, FakeDoc[]>();
  const batchSizes: number[] = [];
  const revokedEvery = counts.revokedEvery ?? 0;

  function docs(path: string, count: number): FakeDoc[] {
    return Array.from({ length: count }, (_unused, index) => {
      const id = `${String(index).padStart(4, "0")}`;
      const data: Record<string, unknown> =
        revokedEvery > 0 && index % revokedEvery === 0 ? { revokedAt: { already: true } } : {};
      return {
        id,
        ref: { path: `${path}/${id}` },
        data,
        get(field: string) {
          return this.data[field];
        },
      };
    });
  }

  collections.set("users/user-1/remote_mcp_clients", docs("users/user-1/remote_mcp_clients", counts.clients));
  collections.set("users/user-1/remote_mcp_grants", docs("users/user-1/remote_mcp_grants", counts.grants));

  const fakeDb = {
    batch() {
      const writes: Array<{ doc: FakeDoc; data: Record<string, unknown> }> = [];
      return {
        set(ref: { path: string }, data: Record<string, unknown>) {
          for (const collectionDocs of collections.values()) {
            const doc = collectionDocs.find((candidate) => candidate.ref.path === ref.path);
            if (doc) {
              writes.push({ doc, data });
              return;
            }
          }
          throw new Error(`unknown ref ${ref.path}`);
        },
        async commit() {
          batchSizes.push(writes.length);
          for (const write of writes) {
            Object.assign(write.doc.data, write.data);
          }
        },
      };
    },
    collection(path: string) {
      const collectionDocs = collections.get(path) ?? [];
      let startAfterId: string | undefined;
      let pageSize = collectionDocs.length;
      const query = {
        orderBy() {
          return query;
        },
        startAfter(doc: FakeDoc) {
          startAfterId = doc.id;
          return query;
        },
        limit(count: number) {
          pageSize = count;
          return query;
        },
        async get() {
          const startIndex = startAfterId
            ? collectionDocs.findIndex((doc) => doc.id === startAfterId) + 1
            : 0;
          const pageDocs = collectionDocs.slice(startIndex, startIndex + pageSize);
          return {
            empty: pageDocs.length === 0,
            docs: pageDocs,
          };
        },
      };
      return query;
    },
  };

  return {
    db: fakeDb as unknown as Firestore,
    batchSizes,
    collections,
  };
}

describe("remote MCP grant revocation", () => {
  it("paginates and chunks revocation below Firestore batch limits", async () => {
    const fake = makeFakeFirestore({ clients: 701, grants: 802, revokedEvery: 100 });

    const result = await revokeAllRemoteMcpGrantsForUser(fake.db, "user-1", "test_suspension");

    expect(result.clientsRevoked).toBe(693);
    expect(result.grantsRevoked).toBe(793);
    expect(fake.batchSizes.length).toBeGreaterThan(2);
    expect(Math.max(...fake.batchSizes)).toBeLessThanOrEqual(450);

    for (const collectionDocs of fake.collections.values()) {
      for (const doc of collectionDocs) {
        expect(doc.data.revokedAt).toBeTruthy();
        if (!("already" in (doc.data.revokedAt as Record<string, unknown>))) {
          expect(doc.data.revokeReason).toBe("test_suspension");
        }
      }
    }
  });
});
