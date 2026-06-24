import { describe, expect, it, vi } from "vitest";

process.env.ENFORCE_APP_CHECK = "false";

type StoredDoc = Record<string, unknown>;

const store = new Map<string, StoredDoc>();

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
  ) {}

  where(field: string, op: string, value: unknown): FakeQuery {
    return new FakeQuery(this.collectionPath, [...this.predicates, { field, op, value }], this.rowLimit);
  }

  limit(rowLimit: number): FakeQuery {
    return new FakeQuery(this.collectionPath, this.predicates, rowLimit);
  }

  async get(): Promise<{ docs: FakeDocumentSnapshot[] }> {
    const prefix = `${this.collectionPath}/`;
    let docs = Array.from(store.entries())
      .filter(([path]) => path.startsWith(prefix) && !path.slice(prefix.length).includes("/"))
      .map(([path, data]) => new FakeDocumentSnapshot(path.split("/").pop() ?? path, data))
      .filter((doc) => this.predicates.every((predicate) => matchesPredicate(doc.data() ?? {}, predicate)));
    if (this.rowLimit !== undefined) docs = docs.slice(0, this.rowLimit);
    return { docs };
  }
}

class FakeCollection {
  constructor(private readonly path: string) {}

  where(field: string, op: string, value: unknown): FakeQuery {
    return new FakeQuery(this.path).where(field, op, value);
  }

  limit(rowLimit: number): FakeQuery {
    return new FakeQuery(this.path).limit(rowLimit);
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
  it("skips scored index rows whose backing session manifest is tombstoned", async () => {
    const tokenHash = "a".repeat(32);
    store.clear();
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
