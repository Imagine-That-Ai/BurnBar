import type { Firestore } from "firebase-admin/firestore";

export interface McpDocSnapshot {
  exists: boolean;
  data(): Record<string, unknown> | undefined;
}

export interface McpDocRef {
  get(): Promise<McpDocSnapshot>;
  set(value: unknown, options?: unknown): Promise<unknown>;
}

export interface McpCollectionQuery {
  get(): Promise<{ docs: Array<{ id: string; get(field: string): unknown }> }>;
}

export interface McpCollectionRef {
  limit(count: number): McpCollectionQuery;
}

export interface McpTransaction {
  get(ref: unknown): Promise<{ get(field: string): unknown }>;
  set(ref: unknown, data: unknown, options?: unknown): void;
}

export interface RemoteMcpClientFirestore {
  doc(documentPath: string): McpDocRef;
}

export interface HostedMcpFirestore extends RemoteMcpClientFirestore {
  collection(collectionPath: string): McpCollectionRef;
  runTransaction<T>(updateFunction: (transaction: McpTransaction) => Promise<T>): Promise<T>;
}

export function isFullFirestore(db: HostedMcpFirestore): db is Firestore {
  return "collectionGroup" in db && typeof db.collectionGroup === "function";
}
