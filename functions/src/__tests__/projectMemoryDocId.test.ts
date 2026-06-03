/**
 * project_memory_snapshots — SEAL + OPAQUE DOC ID (privacy-leak-remediation-
 * 2026-06-02 §2). Proves the commit/get/list callables key the doc by the
 * opaque, vault-key-derived `docID` the device sends and NEVER persist or echo
 * the plaintext `projectSlug`/`projectDisplayName` (both already live inside the
 * sealed `sealedSnapshot` blob). Commit → get round-trips by `docID`, and the
 * stored row + list/get projections carry no plaintext name/slug.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));

// Real validators; only the Pro entitlement gate is stubbed so the call runs
// without Firestore entitlement docs.
vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return {
    ...actual,
    assertActiveBurnBarProEntitlement: vi.fn(async () => undefined),
  };
});

vi.mock("firebase-admin/firestore", () => ({
  Timestamp: { now: () => ({ __ts: true }) },
  AggregateField: { count: () => ({ __count: true }), sum: (f: string) => ({ __sum: f }) },
}));

// In-memory Firestore double keyed by full doc path.
const stored = new Map<string, Record<string, unknown>>();

type FakeRef = {
  __path: string;
  get: () => Promise<unknown>;
  set: (data: Record<string, unknown>, opts?: unknown) => Promise<void>;
};

function makeDb() {
  const docRef = (path: string): FakeRef => ({
    __path: path,
    get: async () => ({
      id: path.split("/").pop(),
      exists: stored.has(path),
      data: () => stored.get(path),
      get: (field: string) => stored.get(path)?.[field],
    }),
    set: async (data: Record<string, unknown>) => void stored.set(path, { ...stored.get(path), ...data }),
  });
  return {
    doc: (path: string) => docRef(path),
    collection: (base: string) => ({
      doc: (id: string) => docRef(`${base}/${id}`),
      orderBy: () => ({
        limit: () => ({
          get: async () => {
            const docs = [...stored.entries()]
              .filter(([k]) => k.startsWith(`${base}/`))
              .map(([k, v]) => ({ id: k.split("/").pop(), data: () => v }));
            return { docs };
          },
        }),
      }),
    }),
  };
}

vi.mock("../adminRuntime.js", () => ({ db: makeDb(), auth: {} }));

process.env.ENFORCE_APP_CHECK = "false";

type Runnable = { run: (request: unknown) => Promise<unknown> };

// A vault-key-derived opaque doc id (matches projectMemoryDocID's shape:
// "pm_" + 32 lowercase hex). The slug/name never travel to the server.
const DOC_ID = "pm_0123456789abcdef0123456789abcdef";
const PLAINTEXT_SLUG = "burnbar-mac-app";
const PLAINTEXT_NAME = "BurnBar Mac App";

function sealedBlob() {
  return {
    schemaVersion: 1,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    plaintextSHA256: "a".repeat(64),
    sealedBoxBase64: Buffer.from("sealed-snapshot-with-name-and-slug-inside").toString("base64"),
    createdAt: "2026-06-02T00:00:00.000Z",
  };
}

function commitRequest() {
  return {
    auth: { uid: "userA", token: {} },
    app: { appId: "test-app" },
    rawRequest: { headers: {} },
    data: {
      docID: DOC_ID,
      contentHash: "b".repeat(64),
      sourceSessionCount: 3,
      sourceConversationCount: 5,
      generatedAt: "2026-06-02T00:00:00.000Z",
      freshness: "fresh",
      visualKinds: ["timeline"],
      sealedSnapshot: sealedBlob(),
    },
  };
}

describe("project_memory_snapshots — opaque docID, no plaintext name/slug", () => {
  beforeEach(() => stored.clear());
  afterEach(() => vi.clearAllMocks());

  it("commit stores the row at the opaque docID with no plaintext slug/name", async () => {
    const { commitEncryptedProjectMemorySnapshot } = await import("../callables/encryptedSearch.js");
    const run = (commitEncryptedProjectMemorySnapshot as unknown as Runnable).run;

    const res = (await run(commitRequest())) as { ok: boolean; docID: string };
    expect(res.ok).toBe(true);
    expect(res.docID).toBe(DOC_ID);

    const record = stored.get(`users/userA/project_memory_snapshots/${DOC_ID}`);
    expect(record).toBeDefined();
    // schemaVersion bumped to 2; opaque docID present; sealed blob present.
    expect(record!.schemaVersion).toBe(2);
    expect(record!.docID).toBe(DOC_ID);
    expect(record!.sealedSnapshot).toBeDefined();
    // No plaintext name/slug anywhere on the stored row.
    expect(record).not.toHaveProperty("projectSlug");
    expect(record).not.toHaveProperty("projectDisplayName");
    const leaves: string[] = [];
    const walk = (v: unknown) => {
      if (typeof v === "string") leaves.push(v);
      else if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === "object") Object.values(v).forEach(walk);
    };
    walk(record);
    expect(leaves).not.toContain(PLAINTEXT_SLUG);
    expect(leaves).not.toContain(PLAINTEXT_NAME);
  });

  it("commit rejects a missing docID", async () => {
    const { commitEncryptedProjectMemorySnapshot } = await import("../callables/encryptedSearch.js");
    const run = (commitEncryptedProjectMemorySnapshot as unknown as Runnable).run;
    const req = commitRequest();
    delete (req.data as Record<string, unknown>).docID;
    await expect(run(req)).rejects.toThrow(/docID/);
  });

  it("get round-trips by docID and echoes no plaintext name/slug", async () => {
    const mod = await import("../callables/encryptedSearch.js");
    await (mod.commitEncryptedProjectMemorySnapshot as unknown as Runnable).run(commitRequest());

    const getRun = (mod.getEncryptedProjectMemorySnapshot as unknown as Runnable).run;
    const res = (await getRun({
      auth: { uid: "userA", token: {} },
      app: { appId: "test-app" },
      rawRequest: { headers: {} },
      data: { docID: DOC_ID },
    })) as { snapshot: Record<string, unknown> | null };

    expect(res.snapshot).not.toBeNull();
    expect(res.snapshot!.docID).toBe(DOC_ID);
    expect(res.snapshot!.sealedSnapshot).toBeDefined();
    expect(res.snapshot).not.toHaveProperty("projectSlug");
    expect(res.snapshot).not.toHaveProperty("projectDisplayName");
  });

  it("list returns only opaque docID + sealed facets (no name/slug projection)", async () => {
    const mod = await import("../callables/encryptedSearch.js");
    await (mod.commitEncryptedProjectMemorySnapshot as unknown as Runnable).run(commitRequest());

    const listRun = (mod.listEncryptedProjectMemorySnapshots as unknown as Runnable).run;
    const res = (await listRun({
      auth: { uid: "userA", token: {} },
      app: { appId: "test-app" },
      rawRequest: { headers: {} },
      data: { limit: 10 },
    })) as { snapshots: Array<Record<string, unknown>> };

    expect(res.snapshots.length).toBe(1);
    const entry = res.snapshots[0];
    expect(entry.docID).toBe(DOC_ID);
    expect(entry).not.toHaveProperty("projectSlug");
    expect(entry).not.toHaveProperty("projectDisplayName");
  });
});
