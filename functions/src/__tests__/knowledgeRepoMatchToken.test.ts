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
import { createHmac } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("firebase-functions/logger", () => ({
  info: vi.fn(),
  error: vi.fn(),
  warn: vi.fn(),
  debug: vi.fn(),
}));
vi.mock("../sentry.js", () => ({ setSentryUser: vi.fn(), captureException: vi.fn() }));
vi.mock("../auth.js", () => ({ enforceAuthAndAppCheck: vi.fn() }));

vi.mock("../callables/shared.js", async () => {
  const actual = await vi.importActual<typeof import("../callables/shared.js")>("../callables/shared.js");
  return {
    ...actual,
    assertActiveBurnBarCloudProEntitlement: vi.fn(async () => undefined),
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
  const docRef = (path: string) => ({
    __path: path,
    get: async () => ({ exists: stored.has(path), data: () => stored.get(path) }),
    set: async (data: Record<string, unknown>) => {
      const merged: Record<string, unknown> = { ...stored.get(path), ...data };
      for (const key of Object.keys(merged)) {
        if (merged[key] === FIELD_DELETE) delete merged[key];
      }
      stored.set(path, merged);
    },
    delete: async () => void stored.delete(path),
  });
  return { doc: (path: string) => docRef(path) };
}

vi.mock("../adminRuntime.js", () => ({ db: makeDb(), auth: {} }));

const MATCH_KEY = "test-repo-match-secret-0123456789";
process.env.KNOWLEDGE_REPO_MATCH_KEY = MATCH_KEY;
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

async function runTestCallable<TResponse>(run: (request: never) => Promise<TResponse>, request: unknown): Promise<TResponse> {
  return run(request as never);
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

describe("connectKnowledgeRepo — server-keyed opaque match token, no cleartext repo name", () => {
  beforeEach(() => stored.clear());
  afterEach(() => vi.clearAllMocks());

  it("stores repoMatchToken + sealed name, never the cleartext repoFullName", async () => {
    const { connectKnowledgeRepo } = await import("../callables/knowledgeSync.js");

    const res = expectRepoResponse(await runTestCallable(connectKnowledgeRepo.run, {
      auth: { uid: "userA", token: {} },
      app: { appId: "test-app" },
      rawRequest: { headers: {} },
      data: { repoFullName: REPO, sealedRepoFullName: sealedName, sourceSlug: "repo-docs-secret" },
    }));

    expect(res.ok).toBe(true);
    const token = expectedToken(REPO);
    expect(res.repoId).toBe(token);

    const record = expectStoredRecord(`users/userA/knowledge_repos/${token}`);
    expect(record.repoMatchToken).toBe(token);
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

  it("is case-insensitive: differently-cased full names map to the SAME token", async () => {
    const { connectKnowledgeRepo } = await import("../callables/knowledgeSync.js");

    const a = expectRepoResponse(await runTestCallable(connectKnowledgeRepo.run, {
      auth: { uid: "userA", token: {} },
      app: { appId: "x" },
      rawRequest: { headers: {} },
      data: { repoFullName: "Owner/Repo", sourceSlug: "s1" },
    }));
    const b = expectRepoResponse(await runTestCallable(connectKnowledgeRepo.run, {
      auth: { uid: "userA", token: {} },
      app: { appId: "x" },
      rawRequest: { headers: {} },
      data: { repoFullName: "owner/repo", sourceSlug: "s1" },
    }));

    expect(a.repoId).toBe(b.repoId);
    expect(a.repoId).toBe(expectedToken("Owner/Repo"));
  });

  it("re-connect strips pre-existing sourceSlug/sourceSlugToken and re-keys to sourceManifestId", async () => {
    const { connectKnowledgeRepo } = await import("../callables/knowledgeSync.js");

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
      data: { repoFullName: REPO, sealedRepoFullName: sealedName, sourceSlug: "repo-docs-secret" },
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
});
