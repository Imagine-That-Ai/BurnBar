/**
 * knowledge_repos — SERVER-KEYED MATCH TOKEN (privacy-leak-remediation-2026-06-02
 * §4). Proves connectKnowledgeRepo persists ONLY an opaque, server-keyed
 * `repoMatchToken` (HMAC of the normalized repo full name) plus a vault-sealed
 * display name — never the cleartext `repoFullName` — and that the doc id is
 * derived from the token, not the name. L40 also proves repo rows persist the
 * canonical `sourceManifestId`, not the transitional `sourceSlugToken` nor the
 * legacy cleartext `sourceSlug`. The same token is recomputable from the
 * GitHub-signed full name (the webhook's match key), which the determinism check
 * below mirrors.
 */
import { EventEmitter } from "node:events";
import { createHmac, generateKeyPairSync } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const assertCloudProMock = vi.hoisted(() => vi.fn(async () => undefined));
const providerFetchMock = vi.hoisted(() => vi.fn());

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));
vi.mock("../providers/httpClient.js", () => ({ providerFetch: providerFetchMock }));

vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return {
    ...actual,
    assertActiveBurnBarCloudProEntitlement: assertCloudProMock,
  };
});

// Sentinel for FieldValue.delete() — the merge-set below strips any key whose
// value is this sentinel, matching Firestore's delete-on-merge semantics so the
// test can prove a stale cleartext slug is removed (not just absent on create).
const FIELD_DELETE = Symbol("FieldValue.delete");

vi.mock("firebase-admin/firestore", () => ({
  Timestamp: { now: () => ({ __ts: true }) },
  getFirestore: () => ({}),
  FieldValue: { delete: () => FIELD_DELETE },
}));

const stored = new Map<string, Record<string, unknown>>();

function makeDb() {
  const refForPath = (path: string) => {
    const parts = path.split("/");
    const collectionId = parts.at(-2);
    const parentDocId = parts.at(-3);
    return { __path: path, path, parent: { id: collectionId, parent: parentDocId ? { id: parentDocId } : undefined } };
  };
  const snapshotForPath = (path: string) => ({
    id: path.split("/").pop(),
    ref: refForPath(path),
    exists: stored.has(path),
    data: () => stored.get(path),
    get: (field: string) => stored.get(path)?.[field],
  });
  const docRef = (path: string) => ({
    __path: path,
    get: async () => snapshotForPath(path),
    set: async (data: Record<string, unknown>) => {
      const merged: Record<string, unknown> = { ...stored.get(path), ...data };
      for (const key of Object.keys(merged)) {
        if (merged[key] === FIELD_DELETE) delete merged[key];
      }
      stored.set(path, merged);
    },
    delete: async () => void stored.delete(path),
  });
  const collectionRef = (path: string) => ({
    limit: (_n: number) => ({
      get: async () => {
        const prefix = `${path}/`;
        const docs = [...stored.keys()]
          .filter((storedPath) => storedPath.startsWith(prefix))
          .map((storedPath) => snapshotForPath(storedPath));
        return { empty: docs.length === 0, size: docs.length, docs };
      },
    }),
  });
  const collectionGroupRef = (collectionId: string) => ({
    where: (field: string, op: string, value: unknown) => ({
      get: async () => {
        if (op !== "==") throw new Error(`Unsupported fake collectionGroup op ${op}`);
        const docs = [...stored.entries()]
          .filter(([storedPath, record]) => storedPath.split("/").at(-2) === collectionId && record[field] === value)
          .map(([storedPath]) => snapshotForPath(storedPath));
        return { empty: docs.length === 0, size: docs.length, docs };
      },
    }),
  });
  return {
    doc: (path: string) => docRef(path),
    collection: (path: string) => collectionRef(path),
    collectionGroup: (collectionId: string) => collectionGroupRef(collectionId),
  };
}

vi.mock("../adminRuntime.js", () => ({ db: makeDb(), auth: {} }));

const MATCH_KEY = "test-repo-match-secret-0123456789";
const WEBHOOK_SECRET = "test-github-webhook-secret";
const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
process.env.KNOWLEDGE_REPO_MATCH_KEY = MATCH_KEY;
process.env.KNOWLEDGE_GITHUB_WEBHOOK_SECRET = WEBHOOK_SECRET;
process.env.KNOWLEDGE_GITHUB_APP_ID = "123456";
process.env.KNOWLEDGE_GITHUB_APP_PRIVATE_KEY = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
process.env.ENFORCE_APP_CHECK = "false";

type RepoResponse = { ok?: boolean; repoId: string };

const REPO = "OpenBurnBar/Secret-Repo";
const sealedName = {
  algorithm: "AES-256-GCM",
  keyVersion: 1,
  nonce: Buffer.from("nonce").toString("base64"),
  ciphertext: Buffer.from("name-ciphertext").toString("base64"),
  tag: Buffer.from("tag").toString("base64"),
};

function expectedToken(fullName: string): string {
  return createHmac("sha256", MATCH_KEY).update(fullName.trim().toLowerCase(), "utf8").digest("hex");
}

function expectedInstallationToken(fullName: string, installId: string): string {
  return createHmac("sha256", MATCH_KEY)
    .update(`repo-installation|${installId}|${fullName.trim().toLowerCase()}`, "utf8")
    .digest("hex");
}

function githubJson(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function mockGitHubRepoAccess(fullName = REPO): void {
  providerFetchMock.mockResolvedValueOnce(githubJson({ token: "installation-token" }));
  providerFetchMock.mockResolvedValueOnce(githubJson({ full_name: fullName }));
}

async function runTestCallable<TResponse>(
  run: (request: never) => Promise<TResponse>,
  request: unknown,
): Promise<TResponse> {
  // @ts-expect-error reason: partial CallableRequest stub for knowledge repo match tests
  return run(request);
}

function expectRepoResponse(raw: unknown): RepoResponse {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("connectKnowledgeRepo returned a non-object response");
  }
  const repoId = "repoId" in raw && typeof raw.repoId === "string" ? raw.repoId : "";
  const ok = "ok" in raw && typeof raw.ok === "boolean" ? raw.ok : undefined;
  if (!repoId) throw new Error("connectKnowledgeRepo response is missing repoId");
  return { ok, repoId };
}

function expectStoredRecord(path: string): Record<string, unknown> {
  const record = stored.get(path);
  expect(record).toBeDefined();
  if (!record) throw new Error(`Missing stored record at ${path}`);
  return record;
}

class FakeRes extends EventEmitter {
  _status = 0;
  _body: unknown = undefined;
  status(code: number): this {
    this._status = code;
    return this;
  }
  json(body: unknown): void {
    this._body = body;
    this.emit("finish");
  }
  send(body?: unknown): void {
    if (body !== undefined) this._body = body;
    this.emit("finish");
  }
  end(): void {
    this.emit("finish");
  }
  set(): void {
    // no-op: enough for the firebase-functions wrapper in this test.
  }
  setHeader(): void {
    // no-op: enough for the firebase-functions wrapper in this test.
  }
  getHeader(): undefined {
    return undefined;
  }
}

async function runHttpHandler(handler: unknown, req: unknown, res: FakeRes): Promise<void> {
  const run = Reflect.get(Object(handler), "run");
  const callable = typeof run === "function" ? run : handler;
  if (typeof callable !== "function") {
    throw new Error("Expected HTTP handler to be callable");
  }
  await callable(req, res);
}

function signedWebhookRequest(body: Record<string, unknown>) {
  const rawBody = Buffer.from(JSON.stringify(body));
  const signature = `sha256=${createHmac("sha256", WEBHOOK_SECRET).update(rawBody).digest("hex")}`;
  const headers: Record<string, string> = {
    "x-github-event": "push",
    "x-hub-signature-256": signature,
  };
  return {
    method: "POST",
    body,
    rawBody,
    header(name: string): string | undefined {
      return headers[name.toLowerCase()];
    },
    get(name: string): string | undefined {
      return headers[name.toLowerCase()];
    },
  };
}

describe("connectKnowledgeRepo — server-keyed opaque match token, no cleartext repo name", () => {
  beforeEach(() => stored.clear());
  afterEach(() => {
    vi.clearAllMocks();
    assertCloudProMock.mockResolvedValue(undefined);
  });

  it("stores repoMatchToken + sealed name, never the cleartext repoFullName", async () => {
    const { connectKnowledgeRepo } = await import("../callables/knowledgeSync.js");
    mockGitHubRepoAccess();

    const res = expectRepoResponse(
      await runTestCallable(connectKnowledgeRepo.run, {
        auth: { uid: "userA", token: {} },
        app: { appId: "test-app" },
        rawRequest: { headers: {} },
        data: {
          repoFullName: REPO,
          sealedRepoFullName: sealedName,
          sourceSlug: "repo-docs-secret",
          installId: "98765",
        },
      }),
    );

    expect(res.ok).toBe(true);
    const token = expectedToken(REPO);
    expect(res.repoId).toBe(token);

    const record = expectStoredRecord(`users/userA/knowledge_repos/${token}`);
    expect(record.repoMatchToken).toBe(token);
    expect(record.repoInstallationMatchToken).toBe(expectedInstallationToken(REPO, "98765"));
    expect(record.sealedRepoFullName).toEqual(sealedName);
    // The cleartext repo name is GONE from the stored row.
    expect(record).not.toHaveProperty("repoFullName");
    // §4/L40 slug remediation: neither the cleartext repo-name-derived
    // `sourceSlug` nor the transitional `sourceSlugToken` is persisted — only
    // the canonical opaque, server-keyed `sourceManifestId` is stored as the
    // manifest routing key.
    expect(record).not.toHaveProperty("sourceSlug");
    expect(record).not.toHaveProperty("sourceSlugToken");
    expect(typeof record.sourceManifestId).toBe("string");
    expect(record.sourceManifestId).toMatch(/^[a-f0-9]{64}$/);
    // The token must be a non-reversible HMAC, never the cleartext slug itself.
    expect(record.sourceManifestId).not.toBe("repo-docs-secret");
    const leaves: string[] = [];
    const walk = (v: unknown) => {
      if (typeof v === "string") leaves.push(v);
      else if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === "object") Object.values(v).forEach(walk);
    };
    walk(record);
    expect(leaves).not.toContain(REPO);
    expect(leaves).not.toContain(REPO.toLowerCase());
    // The reversible cleartext slug must not appear anywhere in the stored row.
    expect(leaves).not.toContain("repo-docs-secret");
  });

  it("exports the installation-bound match-token helper for regression tests", async () => {
    const { __testing__ } = await import("../callables/knowledgeSync.js");

    expect(__testing__.repoInstallationMatchTokenFor(REPO, "98765")).toBe(expectedInstallationToken(REPO, "98765"));
  });

  it("is case-insensitive: differently-cased full names map to the SAME token", async () => {
    const { connectKnowledgeRepo } = await import("../callables/knowledgeSync.js");
    mockGitHubRepoAccess("Owner/Repo");
    mockGitHubRepoAccess("owner/repo");

    const a = expectRepoResponse(
      await runTestCallable(connectKnowledgeRepo.run, {
        auth: { uid: "userA", token: {} },
        app: { appId: "x" },
        rawRequest: { headers: {} },
        data: { repoFullName: "Owner/Repo", sourceSlug: "s1", installId: "98765" },
      }),
    );
    const b = expectRepoResponse(
      await runTestCallable(connectKnowledgeRepo.run, {
        auth: { uid: "userA", token: {} },
        app: { appId: "x" },
        rawRequest: { headers: {} },
        data: { repoFullName: "owner/repo", sourceSlug: "s1", installId: "98765" },
      }),
    );

    expect(a.repoId).toBe(b.repoId);
    expect(a.repoId).toBe(expectedToken("Owner/Repo"));
  });

  it("re-connect strips pre-existing sourceSlug/sourceSlugToken and re-keys to sourceManifestId", async () => {
    const { connectKnowledgeRepo } = await import("../callables/knowledgeSync.js");
    mockGitHubRepoAccess();

    const token = expectedToken(REPO);
    // Seed a LEGACY row in the realistic intermediate state: the repo name was
    // already sealed by the earlier name remediation, but the row still carries
    // the reversible cleartext `sourceSlug` written before the §4 slug fix.
    // (Cleanup of any legacy cleartext `repoFullName` is privacyBackfill's job,
    // not connect's — connect only owns the slug delete asserted here.)
    stored.set(`users/userA/knowledge_repos/${token}`, {
      repoMatchToken: token,
      sealedRepoFullName: sealedName,
      sourceSlugToken: "aa".repeat(32),
      sourceSlug: "repo-docs-secret",
    });

    await runTestCallable(connectKnowledgeRepo.run, {
      auth: { uid: "userA", token: {} },
      app: { appId: "test-app" },
      rawRequest: { headers: {} },
      data: { repoFullName: REPO, sealedRepoFullName: sealedName, sourceSlug: "repo-docs-secret", installId: "98765" },
    });

    const record = expectStoredRecord(`users/userA/knowledge_repos/${token}`);
    // The stale cleartext slug and transitional sourceSlugToken are DELETED on
    // re-connect (merge + FieldValue.delete), not merely absent on a fresh create
    // — this exercises delete-on-merge against a POPULATED legacy row.
    expect(record).not.toHaveProperty("sourceSlug");
    expect(record).not.toHaveProperty("sourceSlugToken");
    // Reads now route through the canonical opaque sourceManifestId.
    expect(record.sourceManifestId).toMatch(/^[a-f0-9]{64}$/);
    const leaves: string[] = [];
    const walk = (v: unknown) => {
      if (typeof v === "string") leaves.push(v);
      else if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === "object") Object.values(v).forEach(walk);
    };
    walk(record);
    expect(leaves).not.toContain("repo-docs-secret");
  });

  it("rejects repo registration when the GitHub App installation cannot access the repo", async () => {
    const { connectKnowledgeRepo } = await import("../callables/knowledgeSync.js");
    providerFetchMock.mockResolvedValueOnce(githubJson({ message: "not found" }, 404));

    await expect(
      runTestCallable(connectKnowledgeRepo.run, {
        auth: { uid: "userA", token: {} },
        app: { appId: "test-app" },
        rawRequest: { headers: {} },
        data: {
          repoFullName: REPO,
          sealedRepoFullName: sealedName,
          sourceSlug: "repo-docs-secret",
          installId: "98765",
        },
      }),
    ).rejects.toThrow("GitHub App installation does not grant access to this repo");

    expect(stored.size).toBe(0);
  });

  it("webhook flags only repos bound to the GitHub installation in the signed payload", async () => {
    const { onKnowledgeRepoPush } = await import("../callables/knowledgeSync.js");
    const repoToken = expectedToken(REPO);
    const matchingManifest = "ab".repeat(32);
    const otherManifest = "cd".repeat(32);
    stored.set(`users/userA/knowledge_repos/${repoToken}`, {
      repoMatchToken: repoToken,
      repoInstallationMatchToken: expectedInstallationToken(REPO, "98765"),
      sourceManifestId: matchingManifest,
    });
    stored.set(`users/userB/knowledge_repos/${repoToken}`, {
      repoMatchToken: repoToken,
      repoInstallationMatchToken: expectedInstallationToken(REPO, "11111"),
      sourceManifestId: otherManifest,
    });

    const res = new FakeRes();
    await runHttpHandler(
      onKnowledgeRepoPush,
      signedWebhookRequest({ repository: { full_name: REPO }, installation: { id: 98765 } }),
      res,
    );

    expect(res._status).toBe(200);
    expect(res._body).toEqual({ ok: true, flagged: 1 });
    expect(stored.get(`users/userA/knowledge_sync_manifests/${matchingManifest}`)?.needsResync).toBe(true);
    expect(stored.get(`users/userB/knowledge_sync_manifests/${otherManifest}`)).toBeUndefined();
  });

  it("webhook keeps legacy repo-token rows live only when their stored installation matches", async () => {
    const { onKnowledgeRepoPush } = await import("../callables/knowledgeSync.js");
    const repoToken = expectedToken(REPO);
    const matchingManifest = "ef".repeat(32);
    const wrongInstallManifest = "12".repeat(32);
    const missingInstallManifest = "34".repeat(32);
    stored.set(`users/userA/knowledge_repos/${repoToken}`, {
      repoMatchToken: repoToken,
      installId: "98765",
      sourceManifestId: matchingManifest,
    });
    stored.set(`users/userB/knowledge_repos/${repoToken}`, {
      repoMatchToken: repoToken,
      installId: "11111",
      sourceManifestId: wrongInstallManifest,
    });
    stored.set(`users/userC/knowledge_repos/${repoToken}`, {
      repoMatchToken: repoToken,
      sourceManifestId: missingInstallManifest,
    });

    const res = new FakeRes();
    await runHttpHandler(
      onKnowledgeRepoPush,
      signedWebhookRequest({ repository: { full_name: REPO }, installation: { id: 98765 } }),
      res,
    );

    expect(res._status).toBe(200);
    expect(res._body).toEqual({ ok: true, flagged: 1 });
    expect(stored.get(`users/userA/knowledge_sync_manifests/${matchingManifest}`)?.needsResync).toBe(true);
    expect(stored.get(`users/userB/knowledge_sync_manifests/${wrongInstallManifest}`)).toBeUndefined();
    expect(stored.get(`users/userC/knowledge_sync_manifests/${missingInstallManifest}`)).toBeUndefined();
  });

  it("webhook does not fall back to repo-name-only matching when installation is missing", async () => {
    const { onKnowledgeRepoPush } = await import("../callables/knowledgeSync.js");
    const repoToken = expectedToken(REPO);
    stored.set(`users/userA/knowledge_repos/${repoToken}`, {
      repoMatchToken: repoToken,
      repoInstallationMatchToken: expectedInstallationToken(REPO, "98765"),
      sourceManifestId: "ab".repeat(32),
    });

    const res = new FakeRes();
    await runHttpHandler(onKnowledgeRepoPush, signedWebhookRequest({ repository: { full_name: REPO } }), res);

    expect(res._status).toBe(202);
    expect(stored.get(`users/userA/knowledge_sync_manifests/${"ab".repeat(32)}`)).toBeUndefined();
  });

  it("requires the Cloud Pro gate before queueing repo resync work", async () => {
    const { requestKnowledgeResync } = await import("../callables/knowledgeSync.js");
    const sourceManifestId = "ab".repeat(32);
    stored.set("users/userA/knowledge_repos/repo-a", { sourceManifestId });
    assertCloudProMock.mockRejectedValueOnce(new Error("cloud pro suspended"));

    await expect(
      runTestCallable(requestKnowledgeResync.run, {
        auth: { uid: "userA", token: {} },
        app: { appId: "test-app" },
        rawRequest: { headers: {} },
        data: {},
      }),
    ).rejects.toThrow("cloud pro suspended");

    expect(assertCloudProMock).toHaveBeenCalledWith("userA");
    expect(stored.get(`users/userA/knowledge_sync_manifests/${sourceManifestId}`)).toBeUndefined();
  });
});
