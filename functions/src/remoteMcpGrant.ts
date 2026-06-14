import { createHash, randomBytes } from "node:crypto";
import { FieldPath, Timestamp, type Firestore } from "firebase-admin/firestore";

export type RemoteMcpGrantMode = "sealed_only" | "local_decrypt_shim" | "remote_readable_explicit_opt_in";
export type RemoteMcpScope = "search:read" | "conversation:read" | "usage:read" | "index:status" | "knowledge:read";

interface RemoteMcpClientDoc {
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

interface RemoteMcpGrantDoc {
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

function randomRemoteMcpSecret(prefix: string): string {
  return `${prefix}_${randomBytes(32).toString("base64url")}`;
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
  // Page each collection (ordered by id) and commit per page, so we revoke ALL
  // clients/grants — not just the first 500 — and never exceed Firestore's
  // 500-op batch limit (a single combined batch could, silently losing revokes).
  const PAGE = 400;
  const revokeCollection = async (collection: string): Promise<number> => {
    const coll = db.collection(`users/${uid}/${collection}`);
    let last: FirebaseFirestore.QueryDocumentSnapshot | undefined;
    let revoked = 0;
    for (;;) {
      let query = coll.orderBy(FieldPath.documentId()).limit(PAGE);
      if (last) query = query.startAfter(last);
      const snap = await query.get();
      if (snap.empty) break;
      const batch = db.batch();
      let writes = 0;
      for (const doc of snap.docs) {
        if (doc.get("revokedAt")) continue;
        batch.set(doc.ref, { revokedAt: now, updatedAt: now, revokeReason: reason }, { merge: true });
        writes += 1;
        revoked += 1;
      }
      if (writes > 0) await batch.commit();
      last = snap.docs[snap.docs.length - 1];
      if (snap.size < PAGE) break;
    }
    return revoked;
  };

  const clientsRevoked = await revokeCollection("remote_mcp_clients");
  const grantsRevoked = await revokeCollection("remote_mcp_grants");
  return { clientsRevoked, grantsRevoked };
}
