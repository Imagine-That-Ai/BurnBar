/**
 * OPUS-F-005 regression tests: account-deletion logs must never contain a full
 * 28-char Firebase UID or a raw Cloud Storage path.
 *
 * These tests exercise the warning paths in `eraseUserCloudData` (secret-destroy
 * failure and storage-purge failure) and assert that the emitted structured log
 * payload is free of raw UIDs/paths and carries only hashed correlation fields.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";

import { eraseUserCloudData } from "../accountDeletion.js";

const FULL_UID = "AbCdEf0123456789AbCdEf012345"; // 28-char Firebase-style UID

function fakeFirestore() {
  const writes: unknown[] = [];
  const batch = {
    delete: vi.fn((ref: unknown) => writes.push(ref)),
    commit: vi.fn(async () => undefined),
  };

  const secretRef = {
    id: `${FULL_UID}_stripe_abc123`,
    get: (field: string) => (field === "secretVersionName" ? "projects/p/secrets/s/versions/1" : undefined),
    ref: {
      path: `provider_account_secret_refs/${FULL_UID}_stripe_abc123`,
      listCollections: async () => [],
    },
  };

  const db = {
    batch: vi.fn(() => batch),
    collection: vi.fn((name: string) => {
      if (name === "provider_account_secret_refs") {
        return {
          listDocuments: async () => [],
          where: vi.fn(() => ({
            get: vi.fn(async () => ({ docs: [secretRef] })),
          })),
        };
      }
      return {
        listDocuments: async () => [],
        where: vi.fn(() => ({
          get: vi.fn(async () => ({ docs: [] })),
        })),
      };
    }),
    doc: vi.fn((path: string) => ({
      path,
      listCollections: vi.fn(async () => []),
    })),
  };

  return { db, batch, writes };
}

describe("account deletion log scrubbing (OPUS-F-005)", () => {
  let warnSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  function emittedPayloads(): string {
    return warnSpy.mock.calls.map((call: readonly unknown[]) => String(call[0])).join("\n");
  }

  it("does not log full UID or raw path when provider credential destroy fails", async () => {
    const { db } = fakeFirestore();
    await eraseUserCloudData(db, FULL_UID, {
      destroyCredential: vi.fn(async () => {
        throw new Error("secret manager rejected destroy");
      }),
      deleteStorageObjects: vi.fn(async () => undefined),
    });

    const emitted = emittedPayloads();
    expect(emitted).not.toContain(FULL_UID);
    expect(emitted).not.toContain(`users/${FULL_UID}`);
    expect(emitted).not.toContain(`avatars/${FULL_UID}`);
    expect(emitted).not.toContain(secretRefDocId());
    expect(emitted).toContain("account_deletion_warning");
    expect(emitted).toContain("user_id_hash");
    expect(emitted).toContain('"account_id_hash":"stripe_a"'); // 8-char account correlation hash
  });

  it("does not log full UID or raw path when Cloud Storage purge fails", async () => {
    const { db } = fakeFirestore();
    await eraseUserCloudData(db, FULL_UID, {
      destroyCredential: vi.fn(async () => undefined),
      deleteStorageObjects: vi.fn(async () => {
        throw new Error("storage bucket unreachable");
      }),
    });

    const emitted = emittedPayloads();
    expect(emitted).not.toContain(FULL_UID);
    expect(emitted).not.toContain(`users/${FULL_UID}`);
    expect(emitted).not.toContain(`avatars/${FULL_UID}`);
    expect(emitted).toContain("storage_prefix_kind");
    expect(emitted).toContain("users");
    expect(emitted).toContain("avatars");
  });

  it("hashes the account identifier instead of logging the full provider_secret_ref doc id", async () => {
    const { db } = fakeFirestore();
    await eraseUserCloudData(db, FULL_UID, {
      destroyCredential: vi.fn(async () => {
        throw new Error("secret manager rejected destroy");
      }),
      deleteStorageObjects: vi.fn(async () => undefined),
    });

    const payload = JSON.parse(String(warnSpy.mock.calls[0]?.[0]));
    expect(payload.account_id_hash).toBe("stripe_a");
    expect(payload.user_id_hash).toBe(FULL_UID.slice(0, 8));
    expect(payload.document_id).toBeUndefined();
  });
});

function secretRefDocId(): string {
  return `${FULL_UID}_stripe_abc123`;
}
