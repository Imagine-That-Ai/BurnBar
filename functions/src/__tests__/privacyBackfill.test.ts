import { describe, expect, it } from "vitest";
import { FieldValue } from "firebase-admin/firestore";

import { __testing__ } from "../callables/privacyBackfill.js";

const { gatedDeletions, COLLECTION_PLANS, KNOWLEDGE_REPO_FIELDS, PRIVACY_RESEAL_EPOCH, backfillUserPrivacy } =
  __testing__;

// FieldValue.delete() returns a fresh sentinel each call, so detect it by the
// admin SDK's structural isEqual rather than reference identity.
function isDeleteSentinel(value: unknown): boolean {
  return value instanceof FieldValue && FieldValue.delete().isEqual(value as FieldValue);
}

// ── Minimal in-memory Firestore double ──────────────────────────────────────
// Supports exactly the surface backfillUserPrivacy uses: collection().doc(),
// collection().listDocuments(), doc(path), get/update/set with FieldValue.delete.
type Doc = Record<string, unknown>;

class FakeDocRef {
  constructor(
    private readonly store: Map<string, Doc>,
    readonly path: string,
  ) {}
  async get() {
    const exists = this.store.has(this.path);
    const data = this.store.get(this.path);
    return {
      exists,
      data: () => (data ? { ...data } : undefined),
      get: (field: string) => (data ? data[field] : undefined),
    };
  }
  async update(patch: Record<string, unknown>) {
    const current = this.store.get(this.path);
    if (!current) throw new Error(`update on missing doc ${this.path}`);
    const next = { ...current };
    for (const [key, value] of Object.entries(patch)) {
      if (isDeleteSentinel(value)) delete next[key];
      else next[key] = value;
    }
    this.store.set(this.path, next);
  }
  async set(patch: Record<string, unknown>, opts?: { merge?: boolean }) {
    const current = opts?.merge ? (this.store.get(this.path) ?? {}) : {};
    this.store.set(this.path, { ...current, ...patch });
  }
  collection(name: string) {
    return new FakeCollectionRef(this.store, `${this.path}/${name}`);
  }
}

class FakeCollectionRef {
  constructor(
    private readonly store: Map<string, Doc>,
    readonly path: string,
  ) {}
  doc(id: string) {
    return new FakeDocRef(this.store, `${this.path}/${id}`);
  }
  async listDocuments() {
    const prefix = `${this.path}/`;
    const ids = new Set<string>();
    for (const key of this.store.keys()) {
      if (!key.startsWith(prefix)) continue;
      const rest = key.slice(prefix.length);
      if (rest.includes("/")) continue; // only direct children
      ids.add(rest);
    }
    return [...ids].map((id) => new FakeDocRef(this.store, `${prefix}${id}`));
  }
}

class FakeFirestore {
  readonly store = new Map<string, Doc>();
  collection(name: string) {
    return new FakeCollectionRef(this.store, name);
  }
  doc(path: string) {
    return new FakeDocRef(this.store, path);
  }
  seed(path: string, data: Doc) {
    this.store.set(path, data);
  }
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  asFirestore() {
    return this as unknown as any;
  }
}

describe("gatedDeletions — safe-by-construction", () => {
  it("deletes a plaintext field ONLY when its sealed gate is present", () => {
    const fields = [{ field: "projectName", requires: "sealedProjectName" }];
    expect(gatedDeletions({ projectName: "secret-proj", sealedProjectName: {} }, fields)).toEqual([
      "projectName",
    ]);
  });

  it("never deletes a plaintext field while its sealed copy is absent", () => {
    const fields = [{ field: "projectName", requires: "sealedProjectName" }];
    expect(gatedDeletions({ projectName: "secret-proj" }, fields)).toEqual([]);
  });

  it("is a no-op when the plaintext field is already gone", () => {
    const fields = [{ field: "projectName", requires: "sealedProjectName" }];
    expect(gatedDeletions({ sealedProjectName: {} }, fields)).toEqual([]);
  });

  it("deletes unconditionally only when no gate is declared", () => {
    expect(gatedDeletions({ legacy: "x" }, [{ field: "legacy" }])).toEqual(["legacy"]);
    expect(gatedDeletions({}, [{ field: "legacy" }])).toEqual([]);
  });

  it("knowledge_repos drops cleartext repoFullName once the sealed name exists", () => {
    expect(gatedDeletions({ repoFullName: "owner/secret" }, KNOWLEDGE_REPO_FIELDS)).toEqual([]);
    expect(
      gatedDeletions({ repoFullName: "owner/secret", sealedRepoFullName: {} }, KNOWLEDGE_REPO_FIELDS),
    ).toEqual(["repoFullName"]);
  });
});

describe("COLLECTION_PLANS coverage", () => {
  it("covers the locked sealable surfaces from the contract", () => {
    const names = COLLECTION_PLANS.map((p) => p.collection);
    for (const expected of [
      "usage",
      "budgetRules",
      "mobile_assistant_chats",
      "cli_sessions",
      "chat_threads",
      "project_memory_snapshots",
    ]) {
      expect(names).toContain(expected);
    }
  });

  it("every gated field declares a sealed gate (no unguarded plaintext deletion)", () => {
    for (const plan of COLLECTION_PLANS) {
      for (const f of plan.fields) {
        expect(f.requires, `${plan.collection}.${f.field} must be gated on a sealed field`).toBeTruthy();
      }
    }
  });
});

describe("backfillUserPrivacy — idempotent end-to-end", () => {
  it("strips gated plaintext, preserves ungated, and bumps the reseal watermark", async () => {
    const fake = new FakeFirestore();
    // Sealed copy present → plaintext is dropped.
    fake.seed("users/u1/usage/a", { projectName: "alpha", sealedProjectName: { ciphertext: "x" }, tokens: 10 });
    // No sealed copy yet → plaintext is preserved (still renders).
    fake.seed("users/u1/usage/b", { projectName: "beta", tokens: 5 });
    // Project memory with sealed snapshot → identity duplicates dropped.
    fake.seed("users/u1/project_memory_snapshots/pm_abc", {
      projectDisplayName: "MySecretApp",
      projectSlug: "my-secret-app",
      sealedSnapshot: { sealedBoxBase64: "z" },
      schemaVersion: 2,
    });
    // knowledge_repos with sealed name → cleartext repo name dropped.
    fake.seed("users/u1/knowledge_repos/r1", {
      repoFullName: "owner/private",
      repoMatchToken: "abc123",
      sealedRepoFullName: { ciphertext: "y" },
    });

    const stats = await backfillUserPrivacy(fake.asFirestore(), "u1");

    expect(stats.deletedFields).toBe(4); // a.projectName, pm.{display,slug}, repo.repoFullName
    expect(stats.resealBumped).toBe(true);

    // Sealed-backed doc: plaintext gone, sealed + metadata intact.
    expect(fake.store.get("users/u1/usage/a")).toEqual({
      sealedProjectName: { ciphertext: "x" },
      tokens: 10,
    });
    // Unsealed doc: plaintext preserved (no data loss in the migration window).
    expect(fake.store.get("users/u1/usage/b")).toEqual({ projectName: "beta", tokens: 5 });
    // Project memory: identity duplicates gone, sealed body + schema intact.
    expect(fake.store.get("users/u1/project_memory_snapshots/pm_abc")).toEqual({
      sealedSnapshot: { sealedBoxBase64: "z" },
      schemaVersion: 2,
    });
    // knowledge_repos: cleartext name gone, opaque token + sealed name intact.
    expect(fake.store.get("users/u1/knowledge_repos/r1")).toEqual({
      repoMatchToken: "abc123",
      sealedRepoFullName: { ciphertext: "y" },
    });
    // Watermark written at the current epoch.
    expect(fake.store.get("users/u1/privacy_reseal_state/current")?.resealEpoch).toBe(PRIVACY_RESEAL_EPOCH);

    // Idempotency: a second run deletes nothing and does not re-bump.
    const again = await backfillUserPrivacy(fake.asFirestore(), "u1");
    expect(again.deletedFields).toBe(0);
    expect(again.updatedDocs).toBe(0);
    expect(again.resealBumped).toBe(false);
  });
});
