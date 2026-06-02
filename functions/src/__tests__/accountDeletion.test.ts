import { describe, expect, it, vi } from "vitest";
import { eraseUserAccount, eraseUserCloudData } from "../accountDeletion.js";

class FakeDocumentSnapshot {
  constructor(
    readonly id: string,
    readonly ref: FakeDocumentReference,
    private readonly fields: Record<string, unknown>,
  ) {}

  get(field: string): unknown {
    return this.fields[field];
  }
}

class FakeDocumentReference {
  constructor(
    readonly path: string,
    private readonly collections: FakeCollectionReference[] = [],
  ) {}

  async listCollections(): Promise<FakeCollectionReference[]> {
    return this.collections;
  }
}

class FakeCollectionReference {
  constructor(private readonly refs: FakeDocumentReference[] = []) {}

  async listDocuments(): Promise<FakeDocumentReference[]> {
    return this.refs;
  }

  where(_field: string, _op: string, _value: string): { get: () => Promise<{ docs: FakeDocumentSnapshot[] }> } {
    return { get: async () => ({ docs: [] }) };
  }
}

class FakeBatch {
  readonly deletedPaths: string[] = [];

  delete(ref: FakeDocumentReference): void {
    this.deletedPaths.push(ref.path);
  }

  async commit(): Promise<void> {}
}

class FakeFirestore {
  readonly batchInstance = new FakeBatch();

  constructor(private readonly secretRefs: FakeDocumentSnapshot[]) {}

  collection(path: string): { where: () => { get: () => Promise<{ docs: FakeDocumentSnapshot[] }> } } {
    expect(path).toBe("provider_account_secret_refs");
    return {
      where: () => ({ get: async () => ({ docs: this.secretRefs }) }),
    };
  }

  doc(path: string): FakeDocumentReference {
    return new FakeDocumentReference(path);
  }

  batch(): FakeBatch {
    return this.batchInstance;
  }
}

function secretRef(id: string, secretVersionName: string): FakeDocumentSnapshot {
  const ref = new FakeDocumentReference(`provider_account_secret_refs/${id}`);
  return new FakeDocumentSnapshot(id, ref, { secretVersionName });
}

describe("account deletion secret retention", () => {
  it("keeps secret refs and skips user document deletion when Secret Manager destruction fails", async () => {
    const db = new FakeFirestore([
      secretRef("uid_account_ok", "projects/p/secrets/ok/versions/1"),
      secretRef("uid_account_failed", "projects/p/secrets/failed/versions/1"),
    ]);
    const logger = { warn: vi.fn() };

    const summary = await eraseUserCloudData(db, "uid123456789", {
      logger,
      destroyCredential: async (name) => {
        if (name.includes("failed")) {
          throw new Error("destroy failed");
        }
      },
    });

    expect(summary.destroyedSecrets).toBe(1);
    expect(summary.failedSecretDestroys).toBe(1);
    expect(summary.deletedDocuments).toBe(1);
    expect(db.batchInstance.deletedPaths).toEqual(["provider_account_secret_refs/uid_account_ok"]);
    expect(db.batchInstance.deletedPaths).not.toContain("provider_account_secret_refs/uid_account_failed");
    expect(db.batchInstance.deletedPaths).not.toContain("users/uid123456789");
    expect(logger.warn.mock.calls[0]?.[0]).toContain("keeping ref for retry");
  });

  it("does not delete the Firebase Auth user while credential destruction is incomplete", async () => {
    const db = new FakeFirestore([secretRef("uid_account_failed", "projects/p/secrets/failed/versions/1")]);
    const deleteAuthUser = vi.fn();

    const result = await eraseUserAccount(db, "uid123456789", {
      deleteAuthUser,
      logger: { warn: vi.fn() },
      destroyCredential: async () => {
        throw new Error("destroy failed");
      },
    });

    expect(result.failedSecretDestroys).toBe(1);
    expect(result.deletedAuthUser).toBe(false);
    expect(deleteAuthUser).not.toHaveBeenCalled();
  });
});
