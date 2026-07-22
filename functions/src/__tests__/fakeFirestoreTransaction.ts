type FakeTransactionRef = {
  get: () => Promise<unknown>;
  set: (data: Record<string, unknown>, options?: unknown) => Promise<void>;
  update?: (data: Record<string, unknown>) => Promise<void>;
  delete?: () => Promise<void>;
};

type FakeTransaction = {
  get: (ref: FakeTransactionRef) => Promise<unknown>;
  set: (ref: FakeTransactionRef, data: Record<string, unknown>, options?: unknown) => void;
  update: (ref: FakeTransactionRef, data: Record<string, unknown>) => void;
  delete: (ref: FakeTransactionRef) => void;
  create: (ref: FakeTransactionRef, data: Record<string, unknown>) => Promise<void>;
};

/**
 * Runs a single-attempt Firestore transaction double. Writes are buffered until
 * the callback succeeds, so a thrown rejection cannot leak a partial commit.
 */
export async function runFakeFirestoreTransaction<T>(fn: (tx: FakeTransaction) => Promise<T>): Promise<T> {
  const writes: Array<() => Promise<void>> = [];
  const tx: FakeTransaction = {
    get: (ref) => ref.get(),
    set: (ref, data, options) => {
      writes.push(() => ref.set(data, options));
    },
    update: (ref, data) => {
      if (!ref.update) throw new TypeError("Transaction reference does not support update");
      writes.push(() => ref.update!(data));
    },
    delete: (ref) => {
      if (!ref.delete) throw new TypeError("Transaction reference does not support delete");
      writes.push(() => ref.delete!());
    },
    create: async (ref, data) => {
      const snapshot = await ref.get();
      if (typeof snapshot === "object" && snapshot !== null && "exists" in snapshot && snapshot.exists) {
        throw new Error("Document already exists");
      }
      writes.push(() => ref.set(data));
    },
  };
  const result = await fn(tx);
  for (const write of writes) await write();
  return result;
}
