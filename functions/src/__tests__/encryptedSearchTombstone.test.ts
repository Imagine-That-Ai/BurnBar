import { describe, expect, it, vi } from "vitest";

process.env.ENFORCE_APP_CHECK = "false";

type StoredDoc = Record<string, unknown>;

const store = new Map<string, StoredDoc>();
const existingStoragePaths = new Set<string>();

class FakeDocumentSnapshot {
  constructor(
    readonly id: string,
    private readonly value: StoredDoc | undefined,
  ) {}

  get exists(): boolean {
    return this.value !== undefined;
  }

  data(): StoredDoc | undefined {
    return this.value;
  }

  get(field: string): unknown {
    return this.value?.[field];
  }
}

class FakeDocumentRef {
  constructor(readonly path: string) {}

  async get(): Promise<FakeDocumentSnapshot> {
    return new FakeDocumentSnapshot(this.path.split("/").pop() ?? this.path, store.get(this.path));
  }
}

type Predicate = { field: string; op: string; value: unknown };

class FakeQuery {
  constructor(
    private readonly collectionPath: string,
    private readonly predicates: Predicate[] = [],
    private readonly rowLimit?: number,
    private readonly afterId?: string,
  ) {}

  where(field: string, op: string, value: unknown): FakeQuery {
    return new FakeQuery(this.collectionPath, [...this.predicates, { field, op, value }], this.rowLimit, this.afterId);
  }

  limit(rowLimit: number): FakeQuery {
    return new FakeQuery(this.collectionPath, this.predicates, rowLimit, this.afterId);
  }

  orderBy(): FakeQuery {
    return new FakeQuery(this.collectionPath, this.predicates, this.rowLimit, this.afterId);
  }

  startAfter(doc: FakeDocumentSnapshot): FakeQuery {
    return new FakeQuery(this.collectionPath, this.predicates, this.rowLimit, doc.id);
  }

  async get(): Promise<{ docs: FakeDocumentSnapshot[]; size: number; empty: boolean }> {
    const prefix = `${this.collectionPath}/`;
    let docs = Array.from(store.entries())
      .filter(([path]) => path.startsWith(prefix) && !path.slice(prefix.length).includes("/"))
      .map(([path, data]) => new FakeDocumentSnapshot(path.split("/").pop() ?? path, data))
      .filter((doc) => this.predicates.every((predicate) => matchesPredicate(doc.data() ?? {}, predicate)));
    if (this.afterId !== undefined) {
      const afterIndex = docs.findIndex((doc) => doc.id === this.afterId);
      docs = afterIndex >= 0 ? docs.slice(afterIndex + 1) : docs;
    }
    if (this.rowLimit !== undefined) docs = docs.slice(0, this.rowLimit);
    return { docs, size: docs.length, empty: docs.length === 0 };
  }
}

class FakeCollection {
  constructor(private readonly path: string) {}

  doc(id: string): FakeDocumentRef {
    return new FakeDocumentRef(`${this.path}/${id}`);
  }

  where(field: string, op: string, value: unknown): FakeQuery {
    return new FakeQuery(this.path).where(field, op, value);
  }

  limit(rowLimit: number): FakeQuery {
    return new FakeQuery(this.path).limit(rowLimit);
  }

  orderBy(): FakeQuery {
    return new FakeQuery(this.path).orderBy();
  }
}

function matchesPredicate(data: StoredDoc, predicate: Predicate): boolean {
  const value = data[predicate.field];
  if (predicate.op === "==") return value === predicate.value;
  if (predicate.op === "in") return Array.isArray(predicate.value) && predicate.value.includes(value);
  if (predicate.op === "array-contains-any") {
    const comparisonValues = Array.isArray(predicate.value) ? predicate.value : [];
    return Array.isArray(value) && value.some((item) => comparisonValues.includes(item));
  }
  return false;
}

const dbMock = {
  collection: (path: string) => new FakeCollection(path),
  doc: (path: string) => new FakeDocumentRef(path),
  getAll: async (...refs: FakeDocumentRef[]) => Promise.all(refs.map((ref) => ref.get())),
};

vi.mock("../adminRuntime.js", () => ({ db: dbMock }));
vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({
    bucket: () => ({
      file: (path: string) => ({
        exists: async () => [existingStoragePaths.has(path)],
        getSignedUrl: async () => [`https://signed.example/${encodeURIComponent(path)}`],
      }),
    }),
  }),
}));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return {
    ...actual,
    assertActiveBurnBarProEntitlement: vi.fn(async () => undefined),
  };
});

type Runnable = { run: (request: unknown) => Promise<unknown> };

function asRunnable(candidate: unknown): Runnable {
  if (
    candidate === null ||
    (typeof candidate !== "object" && typeof candidate !== "function") ||
    !(Reflect.get(candidate, "run") instanceof Function)
  ) {
    throw new Error("callable target is missing run()");
  }
  return { run: (request: unknown) => Reflect.get(candidate, "run")(request) };
}

function callableRequest(uid: string, data: Record<string, unknown>): unknown {
  return {
    auth: { uid, token: {} },
    app: { appId: "openburnbar-test" },
    rawRequest: { headers: {} },
    data,
  };
}

describe("searchEncryptedConversationIndex tombstone filtering", () => {
  it("fills a conversation page after tombstones consume the first raw read", async () => {
    store.clear();
    existingStoragePaths.clear();
    for (let index = 0; index < 500; index += 1) {
      store.set(`users/alice/session_logs/doc-deleted-${index}`, {
        provider: "codex",
        deletedAt: new Date("2026-06-24T00:00:00.000Z"),
      });
    }
    store.set("users/alice/session_logs/doc-live", {
      provider: "codex",
      totalTokens: 123,
      costUSD: 0.42,
      updatedAt: "2026-06-24T00:10:00.000Z",
    });

    const mod = await import("../callables/encryptedSearch.js");
    const target = asRunnable(mod.queryConversations);
    const result = (await target.run(
      callableRequest("alice", {
        limit: 1,
        includeAggregates: true,
      }),
    )) as { rows: Array<Record<string, unknown>>; aggregates: Record<string, unknown> | null };

    expect(result.rows).toHaveLength(1);
    expect(result.rows[0]?.id).toBe("doc-live");
    expect(result.aggregates).toEqual({ count: 1, totalCostUSD: 0.42, totalTokens: 123 });
  });

  it("rejects encrypted blob downloads when the backing manifest is tombstoned", async () => {
    const bodyHash = "a".repeat(64);
    const storagePath = `users/alice/session_logs/doc-deleted/bodies/${bodyHash}.json.aesgcm`;
    store.clear();
    existingStoragePaths.clear();
    existingStoragePaths.add(storagePath);
    store.set("users/alice/session_logs/doc-deleted", {
      storagePath,
      deletedAt: new Date("2026-06-24T00:00:00.000Z"),
    });

    const mod = await import("../callables/encryptedSearch.js");
    const target = asRunnable(mod.getEncryptedSessionBlobDownloadUrl);

    await expect(target.run(callableRequest("alice", { storagePath }))).rejects.toMatchObject({ code: "not-found" });
  });

  it("pages past tombstoned posting batches before returning encrypted-search hits", async () => {
    const tokenHash = "b".repeat(32);
    store.clear();
    existingStoragePaths.clear();
    for (let index = 0; index < 500; index += 1) {
      const documentID = `doc-deleted-${index}`;
      const chunkID = `${documentID}_0`;
      const bodyHash = index.toString(16).padStart(64, "0");
      const storagePath = `users/alice/session_logs/${documentID}/bodies/${bodyHash}.json.aesgcm`;
      store.set(`users/alice/cloud_search_postings/post-deleted-${index}`, {
        postingKey: `token_${tokenHash}`,
        kind: "token",
        hash: tokenHash,
        chunkID,
        provider: "codex",
      });
      store.set(`users/alice/cloud_search_chunks/${chunkID}`, {
        documentID,
        provider: "codex",
        tokenHashes: [tokenHash],
        bodyHash,
        storagePath,
        ordinal: index,
      });
      store.set(`users/alice/cloud_search_documents/${documentID}`, {
        bodyHash,
        storagePath,
      });
      store.set(`users/alice/session_logs/${documentID}`, {
        deletedAt: new Date("2026-06-24T00:00:00.000Z"),
      });
    }
    const liveBodyHash = "c".repeat(64);
    store.set("users/alice/cloud_search_postings/post-live", {
      postingKey: `token_${tokenHash}`,
      kind: "token",
      hash: tokenHash,
      chunkID: "doc-live_0",
      provider: "codex",
    });
    store.set("users/alice/cloud_search_chunks/doc-live_0", {
      documentID: "doc-live",
      provider: "codex",
      tokenHashes: [tokenHash],
      bodyHash: liveBodyHash,
      storagePath: `users/alice/session_logs/doc-live/bodies/${liveBodyHash}.json.aesgcm`,
      ordinal: 501,
    });
    store.set("users/alice/cloud_search_documents/doc-live", {
      bodyHash: liveBodyHash,
      storagePath: `users/alice/session_logs/doc-live/bodies/${liveBodyHash}.json.aesgcm`,
    });
    store.set("users/alice/session_logs/doc-live", {
      id: "live",
    });

    const mod = await import("../callables/encryptedSearch.js");
    const target = asRunnable(mod.searchEncryptedConversationIndex);
    const result = (await target.run(
      callableRequest("alice", {
        tokenHashes: [tokenHash],
        semanticHashes: [],
        provider: "codex",
        limit: 1,
      }),
    )) as { hits: Array<Record<string, unknown>> };

    expect(result.hits).toHaveLength(1);
    expect(result.hits[0]?.documentID).toBe("doc-live");
  });

  it("skips scored index rows whose backing session manifest is tombstoned", async () => {
    const tokenHash = "a".repeat(32);
    store.clear();
    existingStoragePaths.clear();
    store.set("users/alice/cloud_search_postings/post-deleted", {
      postingKey: `token_${tokenHash}`,
      kind: "token",
      hash: tokenHash,
      chunkID: "doc-deleted_0",
      provider: "codex",
    });
    store.set("users/alice/cloud_search_postings/post-live", {
      postingKey: `token_${tokenHash}`,
      kind: "token",
      hash: tokenHash,
      chunkID: "doc-live_0",
      provider: "codex",
    });
    store.set("users/alice/cloud_search_chunks/doc-deleted_0", {
      documentID: "doc-deleted",
      provider: "codex",
      tokenHashes: [tokenHash],
      bodyHash: "deleted-hash",
      storagePath: "users/alice/session_logs/doc-deleted/bodies/deleted.json.aesgcm",
      ordinal: 0,
    });
    store.set("users/alice/cloud_search_chunks/doc-live_0", {
      documentID: "doc-live",
      provider: "codex",
      tokenHashes: [tokenHash],
      bodyHash: "live-hash",
      storagePath: "users/alice/session_logs/doc-live/bodies/live.json.aesgcm",
      ordinal: 1,
    });
    store.set("users/alice/cloud_search_documents/doc-deleted", {
      bodyHash: "deleted-hash",
      storagePath: "users/alice/session_logs/doc-deleted/bodies/deleted.json.aesgcm",
    });
    store.set("users/alice/cloud_search_documents/doc-live", {
      bodyHash: "live-hash",
      storagePath: "users/alice/session_logs/doc-live/bodies/live.json.aesgcm",
    });
    store.set("users/alice/session_logs/doc-deleted", {
      deletedAt: new Date("2026-06-24T00:00:00.000Z"),
    });
    store.set("users/alice/session_logs/doc-live", {
      id: "live",
    });

    const mod = await import("../callables/encryptedSearch.js");
    const target = asRunnable(mod.searchEncryptedConversationIndex);
    const result = (await target.run(
      callableRequest("alice", {
        tokenHashes: [tokenHash],
        semanticHashes: [],
        provider: "codex",
        limit: 1,
      }),
    )) as { hits: Array<Record<string, unknown>> };

    expect(result.hits).toHaveLength(1);
    expect(result.hits[0]?.documentID).toBe("doc-live");
  });
});
