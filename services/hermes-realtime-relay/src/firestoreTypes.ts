export interface EntitlementDocSnapshot {
  exists: boolean;
  data(): Record<string, unknown> | undefined;
}

export interface EntitlementDocRef {
  get(): Promise<EntitlementDocSnapshot>;
}

export interface EntitlementFirestore {
  doc(documentPath: string): EntitlementDocRef;
}
