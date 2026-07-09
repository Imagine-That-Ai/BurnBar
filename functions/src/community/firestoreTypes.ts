/**
 * Minimal Firestore surface used by Community pure functions and tests.
 *
 * Production passes Firebase Admin `Firestore`; unit tests pass the path-keyed
 * in-memory fake. Keeping this structural avoids unsafe `as unknown as Firestore`
 * casts in tests while still compiling against the real Admin SDK.
 */
export interface CommunityDocumentSnapshot { readonly exists?: boolean; data(): unknown; }

export interface CommunityDocumentParent { readonly id?: string; readonly parent?: CommunityDocumentParent | null; }

export interface CommunityDocumentReference {
  readonly path: string;
  readonly parent?: CommunityDocumentParent | null;
  get(): Promise<CommunityDocumentSnapshot>;
  set(data: Record<string, unknown>, options?: { readonly merge?: boolean }): Promise<unknown>;
  delete(): Promise<unknown>;
}

interface CommunityQueryDocumentSnapshot extends CommunityDocumentSnapshot {
  readonly id: string;
  readonly ref: CommunityDocumentReference;
}

interface CommunityQuerySnapshot { readonly docs: readonly CommunityQueryDocumentSnapshot[]; readonly empty?: boolean; readonly size?: number; }

export interface CommunityQuery { get(): Promise<CommunityQuerySnapshot>; }

export interface CommunityCollectionReference extends CommunityQuery { doc(id: string): CommunityDocumentReference; }

export interface CommunityWriteBatch { delete(ref: CommunityDocumentReference): unknown; commit(): Promise<unknown>; }

export interface CommunityFirestoreReader { doc(path: string): CommunityDocumentReference; }

export interface CommunityFirestore extends CommunityFirestoreReader {
  collection(name: string): CommunityCollectionReference;
  collectionGroup(name: string): CommunityQuery;
  batch(): CommunityWriteBatch;
}
