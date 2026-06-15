import { expect } from "vitest";
import type { CallableRequest } from "firebase-functions/v2/https";

export const ALICE_UID = "alice-bola-uid";
export const BOB_UID = "bob-bola-uid";

export function callableRequest<T extends Record<string, unknown>>(
  uid: string,
  data: T,
): CallableRequest<T> {
  return {
    auth: { uid, token: {} },
    app: { appId: "openburnbar-test" },
    rawRequest: { headers: {} },
    data,
  } as CallableRequest<T>;
}

export function callableRunner(candidate: unknown): (request: unknown) => Promise<unknown> {
  if (
    candidate === null ||
    (typeof candidate !== "object" && typeof candidate !== "function") ||
    !("run" in candidate)
  ) {
    throw new Error("callable test target is missing run()");
  }
  const { run } = candidate as { run: (request: unknown) => Promise<unknown> };
  if (typeof run !== "function") {
    throw new Error("callable test target run property is not callable");
  }
  return async (request: unknown) => run.call(candidate, request);
}

export async function expectCallableDenial(
  run: (request: unknown) => Promise<unknown>,
  request: unknown,
  expectedCode: "permission-denied" | "not-found" | "failed-precondition" | "unauthenticated",
): Promise<void> {
  try {
    await run(request);
    expect.fail(`expected callable to reject with ${expectedCode}`);
  } catch (error) {
    const code =
      error &&
      typeof error === "object" &&
      "code" in error &&
      typeof (error as { code?: unknown }).code === "string"
        ? (error as { code: string }).code
        : String(error);
    if (code.includes(expectedCode) || code === expectedCode) {
      return;
    }
    // Some handlers throw plain Error strings like "not-found: ..."
    if (code.toLowerCase().includes(expectedCode)) {
      return;
    }
    throw error;
  }
}

export type PathKeyedStore = Map<string, Record<string, unknown>>;

export function pathKeyedFirestore(store: PathKeyedStore) {
  return {
    doc: (path: string) => ({
      get: async () => {
        const data = store.get(path);
        return {
          exists: data !== undefined,
          data: () => data,
          get: (field: string) => data?.[field],
        };
      },
      set: async (data: Record<string, unknown>) => {
        store.set(path, { ...(store.get(path) ?? {}), ...data });
      },
      update: async (data: Record<string, unknown>) => {
        store.set(path, { ...(store.get(path) ?? {}), ...data });
      },
      delete: async () => {
        store.delete(path);
      },
    }),
    collection: (name: string) => ({
      doc: (id: string) => pathKeyedFirestore(store).doc(`${name}/${id}`),
      add: async (data: Record<string, unknown>) => {
        const id = `auto-${store.size + 1}`;
        const path = `${name}/${id}`;
        store.set(path, data);
        return { id, path };
      },
      where: () => ({
        get: async () => ({ docs: [], empty: true }),
      }),
    }),
    batch: () => {
      const ops: Array<() => void> = [];
      return {
        delete: (ref: { path?: string }) => {
          if (ref.path) ops.push(() => store.delete(ref.path!));
        },
        set: (ref: { path?: string }, data: Record<string, unknown>) => {
          if (ref.path) ops.push(() => store.set(ref.path!, data));
        },
        update: (ref: { path?: string }, data: Record<string, unknown>) => {
          if (ref.path) ops.push(() => store.set(ref.path!, { ...(store.get(ref.path!) ?? {}), ...data }));
        },
        commit: async () => {
          for (const op of ops) op();
        },
      };
    },
    runTransaction: async (fn: (tx: unknown) => Promise<unknown>) => {
      const tx = {
        get: async (ref: { get: () => Promise<unknown> }) => ref.get(),
        set: (ref: { set: (d: Record<string, unknown>) => Promise<void> }, data: Record<string, unknown>) =>
          ref.set(data),
        update: (ref: { update: (d: Record<string, unknown>) => Promise<void> }, data: Record<string, unknown>) =>
          ref.update(data),
        delete: (ref: { delete: () => Promise<void> }) => ref.delete(),
      };
      return fn(tx as never);
    },
  };
}

export function seedDoc(store: PathKeyedStore, path: string, data: Record<string, unknown>): void {
  store.set(path, data);
}