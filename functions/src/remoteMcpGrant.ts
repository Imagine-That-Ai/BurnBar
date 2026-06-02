import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { FieldPath, Timestamp, type Firestore } from "firebase-admin/firestore";

export type RemoteMcpGrantMode = "sealed_only" | "local_decrypt_shim" | "remote_readable_explicit_opt_in";
export type RemoteMcpScope = "search:read" | "conversation:read" | "usage:read" | "index:status";

export interface RemoteMcpClientDoc {
  clientId: string;
  displayName: string;
  clientType: string;
  installFingerprintHash?: string;
  allowedScopes: RemoteMcpScope[];
  grantMode: RemoteMcpGrantMode;
  createdAt: FirebaseFirestore.Timestamp;
  updatedAt: FirebaseFirestore.Timestamp;
  lastUsedAt?: FirebaseFirestore.Timestamp;
  revokedAt?: FirebaseFirestore.Timestamp;
  schemaVersion: 1;
}

export interface RemoteMcpGrantDoc {
  grantId: string;
  clientId: string;
  scopes: RemoteMcpScope[];
  tokenFamilyHash: string;
  refreshTokenHash: string;
  expiresAt: FirebaseFirestore.Timestamp;
  revokedAt?: FirebaseFirestore.Timestamp;
  entitlementSnapshot: {
    family: "burnbar_pro" | "hosted_quota_sync";
    expiresAt?: string;
  };
  createdAt: FirebaseFirestore.Timestamp;
  updatedAt: FirebaseFirestore.Timestamp;
  schemaVersion: 1;
}

export function hashRemoteMcpSecret(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

export function randomRemoteMcpSecret(prefix: string): string {
  return `${prefix}_${randomBytes(32).toString("base64url")}`;
}

export function safeEqualHash(raw: string, expectedHash: string): boolean {
  const actual = Buffer.from(hashRemoteMcpSecret(raw), "hex");
  const expected = Buffer.from(expectedHash, "hex");
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

export async function upsertRemoteMcpClient(
  db: Firestore,
  uid: string,
  input: {
    clientId: string;
    displayName: string;
    clientType: string;
    installFingerprint?: string;
    allowedScopes: RemoteMcpScope[];
    grantMode: RemoteMcpGrantMode;
  },
): Promise<RemoteMcpClientDoc> {
  const now = Timestamp.now();
  const doc: RemoteMcpClientDoc = {
    clientId: input.clientId,
    displayName: input.displayName,
    clientType: input.clientType,
    installFingerprintHash: input.installFingerprint ? hashRemoteMcpSecret(input.installFingerprint) : undefined,
    allowedScopes: input.allowedScopes,
    grantMode: input.grantMode,
    createdAt: now,
    updatedAt: now,
    schemaVersion: 1,
  };
  await db.doc(`users/${uid}/remote_mcp_clients/${input.clientId}`).set(doc, { merge: true });
  return doc;
}

export async function createRemoteMcpGrant(
  db: Firestore,
  uid: string,
  input: {
    clientId: string;
    scopes: RemoteMcpScope[];
    entitlementFamily: "burnbar_pro" | "hosted_quota_sync";
    entitlementExpiresAt?: string;
  },
): Promise<{ grant: RemoteMcpGrantDoc; refreshToken: string }> {
  const now = Timestamp.now();
  const grantId = `rmg_${randomBytes(16).toString("hex")}`;
  const refreshToken = randomRemoteMcpSecret("obbr");
  const grant: RemoteMcpGrantDoc = {
    grantId,
    clientId: input.clientId,
    scopes: input.scopes,
    tokenFamilyHash: hashRemoteMcpSecret(`${grantId}:${input.clientId}`),
    refreshTokenHash: hashRemoteMcpSecret(refreshToken),
    expiresAt: Timestamp.fromMillis(Date.now() + 90 * 24 * 60 * 60 * 1000),
    entitlementSnapshot: {
      family: input.entitlementFamily,
      expiresAt: input.entitlementExpiresAt,
    },
    createdAt: now,
    updatedAt: now,
    schemaVersion: 1,
  };
  await db.doc(`users/${uid}/remote_mcp_grants/${grantId}`).set(grant);
  return { grant, refreshToken };
}

export async function revokeRemoteMcpClient(db: Firestore, uid: string, clientId: string): Promise<void> {
  const now = Timestamp.now();
  await db.doc(`users/${uid}/remote_mcp_clients/${clientId}`).set({ revokedAt: now, updatedAt: now }, { merge: true });
  const grants = await db
    .collection(`users/${uid}/remote_mcp_grants`)
    .where("clientId", "==", clientId)
    .limit(100)
    .get();
  const batch = db.batch();
  for (const grant of grants.docs) {
    batch.set(grant.ref, { revokedAt: now, updatedAt: now }, { merge: true });
  }
  await batch.commit();
}

export async function revokeAllRemoteMcpGrantsForUser(
  db: Firestore,
  uid: string,
  reason = "cloud_feature_suspension",
): Promise<{ clientsRevoked: number; grantsRevoked: number }> {
  const now = Timestamp.now();
  const clientsRevoked = await revokeAllInCollection(db, `users/${uid}/remote_mcp_clients`, now, reason);
  const grantsRevoked = await revokeAllInCollection(db, `users/${uid}/remote_mcp_grants`, now, reason);
  return { clientsRevoked, grantsRevoked };
}

async function revokeAllInCollection(
  db: Firestore,
  collectionPath: string,
  now: FirebaseFirestore.Timestamp,
  reason: string,
): Promise<number> {
  const pageSize = 450;
  let lastDoc: FirebaseFirestore.QueryDocumentSnapshot | undefined;
  let revoked = 0;

  while (true) {
    let query = db.collection(collectionPath).orderBy(FieldPath.documentId()).limit(pageSize);
    if (lastDoc) query = query.startAfter(lastDoc);
    const page = await query.get();
    if (page.empty) break;

    const batch = db.batch();
    let writes = 0;
    for (const doc of page.docs) {
      if (doc.get("revokedAt")) continue;
      batch.set(doc.ref, { revokedAt: now, updatedAt: now, revokeReason: reason }, { merge: true });
      writes += 1;
    }
    if (writes > 0) {
      await batch.commit();
      revoked += writes;
    }

    lastDoc = page.docs[page.docs.length - 1];
    if (page.docs.length < pageSize) break;
  }

  return revoked;
}
