/**
 * knowledge_repos — SERVER-KEYED MATCH TOKEN (privacy-leak-remediation-2026-06-02
 * §4). Proves connectKnowledgeRepo persists ONLY an opaque, server-keyed
 * `repoMatchToken` (HMAC of the normalized repo full name) plus a vault-sealed
 * display name — never the cleartext `repoFullName` — and that the doc id is
 * derived from the token, not the name. The same token is recomputable from the
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

vi.mock("firebase-admin/firestore", () => ({
  Timestamp: { now: () => ({ __ts: true }) },
  getFirestore: () => ({}),
}));

const stored = new Map<string, Record<string, unknown>>();

function makeDb() {
  const docRef = (path: string) => ({
    __path: path,
    get: async () => ({ exists: stored.has(path), data: () => stored.get(path) }),
    set: async (data: Record<string, unknown>) => void stored.set(path, { ...stored.get(path), ...data }),
    delete: async () => void stored.delete(path),
  });
  return { doc: (path: string) => docRef(path) };
}

vi.mock("../adminRuntime.js", () => ({ db: makeDb(), auth: {} }));

const MATCH_KEY = "test-repo-match-secret-0123456789";
process.env.KNOWLEDGE_REPO_MATCH_KEY = MATCH_KEY;
process.env.ENFORCE_APP_CHECK = "false";

type Runnable = { run: (request: unknown) => Promise<unknown> };

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

describe("connectKnowledgeRepo — server-keyed opaque match token, no cleartext repo name", () => {
  beforeEach(() => stored.clear());
  afterEach(() => vi.clearAllMocks());

  it("stores repoMatchToken + sealed name, never the cleartext repoFullName", async () => {
    const { connectKnowledgeRepo } = await import("../callables/knowledgeSync.js");
    const run = (connectKnowledgeRepo as unknown as Runnable).run;

    const res = (await run({
      auth: { uid: "userA", token: {} },
      app: { appId: "test-app" },
      rawRequest: { headers: {} },
      data: { repoFullName: REPO, sealedRepoFullName: sealedName, sourceSlug: "repo-docs-secret" },
    })) as { ok: boolean; repoId: string };

    expect(res.ok).toBe(true);
    const token = expectedToken(REPO);
    expect(res.repoId).toBe(token);

    const record = stored.get(`users/userA/knowledge_repos/${token}`);
    expect(record).toBeDefined();
    expect(record!.repoMatchToken).toBe(token);
    expect(record!.sealedRepoFullName).toEqual(sealedName);
    // The cleartext repo name is GONE from the stored row.
    expect(record).not.toHaveProperty("repoFullName");
    const leaves: string[] = [];
    const walk = (v: unknown) => {
      if (typeof v === "string") leaves.push(v);
      else if (Array.isArray(v)) v.forEach(walk);
      else if (v && typeof v === "object") Object.values(v).forEach(walk);
    };
    walk(record);
    expect(leaves).not.toContain(REPO);
    expect(leaves).not.toContain(REPO.toLowerCase());
  });

  it("is case-insensitive: differently-cased full names map to the SAME token", async () => {
    const { connectKnowledgeRepo } = await import("../callables/knowledgeSync.js");
    const run = (connectKnowledgeRepo as unknown as Runnable).run;

    const a = (await run({
      auth: { uid: "userA", token: {} },
      app: { appId: "x" },
      rawRequest: { headers: {} },
      data: { repoFullName: "Owner/Repo", sourceSlug: "s1" },
    })) as { repoId: string };
    const b = (await run({
      auth: { uid: "userA", token: {} },
      app: { appId: "x" },
      rawRequest: { headers: {} },
      data: { repoFullName: "owner/repo", sourceSlug: "s1" },
    })) as { repoId: string };

    expect(a.repoId).toBe(b.repoId);
    expect(a.repoId).toBe(expectedToken("Owner/Repo"));
  });
});
