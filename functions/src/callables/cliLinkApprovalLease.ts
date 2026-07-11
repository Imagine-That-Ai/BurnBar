import { FieldValue, Timestamp } from "firebase-admin/firestore";
import type { SetOptions } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { randomBytes } from "node:crypto";

import type { CliLinkPurpose, CliLinkSessionDoc } from "./cliLink.js";

const APPROVAL_CLAIM_LEASE_MS = 60_000;

type SessionReader = (raw: FirebaseFirestore.DocumentData | undefined) => CliLinkSessionDoc | undefined;

export interface CliLinkApprovalTransactionWriter {
  doc(path: string): {
    set(data: object, options?: { merge?: boolean }): Promise<unknown>;
  };
}

export async function claimCliLinkSessionForApproval(
  db: FirebaseFirestore.Firestore,
  sessionRef: FirebaseFirestore.DocumentReference,
  uid: string,
  expectedPurpose: CliLinkPurpose,
  readSession: SessionReader,
): Promise<{ session: CliLinkSessionDoc; claimID: string }> {
  const claimID = randomBytes(16).toString("base64url");
  return db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(sessionRef);
    const session = readSession(snapshot.data());
    if (!snapshot.exists || !session || session.expiresAt.toMillis() < Date.now()) {
      throw new HttpsError("failed-precondition", "This link code has expired.");
    }
    const claimIsStale =
      session.status === "approving" &&
      session.approvalClaimedAt != null &&
      session.approvalClaimedAt.toMillis() <= Date.now() - APPROVAL_CLAIM_LEASE_MS;
    if (session.status !== "pending" && !claimIsStale) {
      throw new HttpsError("failed-precondition", "This link code is already being approved or was consumed.");
    }
    if (session.purpose !== expectedPurpose) {
      throw new HttpsError("failed-precondition", "The displayed link purpose does not match this session.");
    }
    transaction.update(sessionRef, {
      status: "approving",
      approvalClaimUid: uid,
      approvalClaimID: claimID,
      approvalClaimedAt: Timestamp.now(),
    });
    return { session, claimID };
  });
}

export async function releaseCliLinkApprovalClaim(
  db: FirebaseFirestore.Firestore,
  sessionRef: FirebaseFirestore.DocumentReference,
  uid: string,
  claimID: string,
): Promise<void> {
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(sessionRef);
    const data = snapshot.data();
    if (
      !snapshot.exists ||
      data?.status !== "approving" ||
      data.approvalClaimUid !== uid ||
      data.approvalClaimID !== claimID
    ) {
      return;
    }
    transaction.update(sessionRef, {
      status: "pending",
      approvalClaimUid: FieldValue.delete(),
      approvalClaimID: FieldValue.delete(),
      approvalClaimedAt: FieldValue.delete(),
    });
  });
}

export async function finalizeCliLinkApproval(
  db: FirebaseFirestore.Firestore,
  sessionRef: FirebaseFirestore.DocumentReference,
  uid: string,
  claimID: string,
  update: FirebaseFirestore.UpdateData<FirebaseFirestore.DocumentData>,
): Promise<void> {
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(sessionRef);
    const data = snapshot.data();
    const expiresAt = data?.expiresAt;
    if (
      !snapshot.exists ||
      data?.status !== "approving" ||
      data.approvalClaimUid !== uid ||
      data.approvalClaimID !== claimID ||
      !(expiresAt instanceof Timestamp) ||
      expiresAt.toMillis() < Date.now()
    ) {
      throw new HttpsError("failed-precondition", "This link approval lease is no longer active.");
    }
    transaction.update(sessionRef, update);
  });
}

export async function finalizeCliLinkApprovalWithWrites<Result>(
  db: FirebaseFirestore.Firestore,
  sessionRef: FirebaseFirestore.DocumentReference,
  uid: string,
  claimID: string,
  stage: (
    writer: CliLinkApprovalTransactionWriter,
  ) => Promise<{ update: FirebaseFirestore.UpdateData<FirebaseFirestore.DocumentData>; result: Result }>,
): Promise<Result> {
  return db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(sessionRef);
    const data = snapshot.data();
    const expiresAt = data?.expiresAt;
    if (
      !snapshot.exists ||
      data?.status !== "approving" ||
      data.approvalClaimUid !== uid ||
      data.approvalClaimID !== claimID ||
      !(expiresAt instanceof Timestamp) ||
      expiresAt.toMillis() < Date.now()
    ) {
      throw new HttpsError("failed-precondition", "This link approval lease is no longer active.");
    }

    const writer: CliLinkApprovalTransactionWriter = {
      doc: (path) => ({
        set: async (document, options) => {
          const reference = db.doc(path);
          if (options) {
            transaction.set(reference, document, options as SetOptions);
          } else {
            transaction.set(reference, document);
          }
        },
      }),
    };
    const staged = await stage(writer);
    transaction.update(sessionRef, staged.update);
    return staged.result;
  });
}
