/** Authenticated, App Check-bound encrypted replica synchronization for Linux. */

import { createHash } from "node:crypto";
import { FieldValue, type DocumentData, type DocumentReference } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { assertAppCheck, assertAuth } from "../auth.js";
import { getConfig } from "../config.js";
import { onCallProduction } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

const SUPPORTED_DOMAINS = new Set(["usage", "conversations", "session_logs", "text_expansion", "roaming_profile"]);
const MAX_MUTATIONS = 200;
const MAX_PULL_LIMIT = 500;
const MAX_REPLICA_BYTES = 768 * 1024;
const MAX_RECORD_ID_BYTES = 2048;
const MAX_CURSOR = Number.MAX_SAFE_INTEGER - 1;

interface LinuxCloudSealedPayload {
  schemaVersion?: number;
  algorithm: "AES-256-GCM";
  keyVersion: number;
  nonce: string;
  ciphertext: string;
  tag: string;
  aad?: string;
}

interface LinuxCloudRemoteReplica {
  domain: string;
  recordID: string;
  revision: number;
  modifiedAtMillis: number;
  sourceDeviceID: string;
  tombstone: boolean;
  sealedPayload: LinuxCloudSealedPayload | null;
}

interface LinuxCloudOutboundMutation {
  sequence: number;
  mutationID: string;
  replica: LinuxCloudRemoteReplica;
}

function invalid(message: string): never {
  throw new HttpsError("invalid-argument", message);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function exactKeys(value: Record<string, unknown>, required: string[], optional: string[] = []): void {
  const allowed = new Set([...required, ...optional]);
  if (required.some((key) => !(key in value)) || Object.keys(value).some((key) => !allowed.has(key))) {
    invalid("Cloud replica payload has an invalid shape.");
  }
}

function identifier(value: unknown, maximumBytes = MAX_RECORD_ID_BYTES): string {
  if (typeof value !== "string" || value.length === 0 || Buffer.byteLength(value, "utf8") > maximumBytes) {
    return invalid("Cloud replica identifier is invalid.");
  }
  for (const character of value) {
    const scalar = character.codePointAt(0) ?? 0;
    if (scalar < 0x20 || scalar === 0x7f || character === "|") return invalid("Cloud replica identifier is invalid.");
  }
  return value;
}

function integer(value: unknown, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) {
    return invalid("Cloud replica integer is outside its supported range.");
  }
  return value;
}

function base64(value: unknown, exactBytes?: number, maximumBytes?: number): string {
  if (typeof value !== "string" || value.length === 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
    return invalid("Cloud replica ciphertext encoding is invalid.");
  }
  const decoded = Buffer.from(value, "base64");
  if (decoded.toString("base64") !== value || (exactBytes !== undefined && decoded.length !== exactBytes)) {
    return invalid("Cloud replica ciphertext encoding is invalid.");
  }
  if (maximumBytes !== undefined && decoded.length > maximumBytes) {
    return invalid("Cloud replica ciphertext exceeds the supported size.");
  }
  return value;
}

function parseSealedPayload(value: unknown): LinuxCloudSealedPayload {
  if (!isRecord(value)) return invalid("A non-tombstone replica requires sealed ciphertext.");
  exactKeys(value, ["algorithm", "keyVersion", "nonce", "ciphertext", "tag"], ["schemaVersion", "aad"]);
  if (value.algorithm !== "AES-256-GCM") return invalid("Cloud replica encryption algorithm is unsupported.");
  const result: LinuxCloudSealedPayload = {
    algorithm: "AES-256-GCM",
    keyVersion: integer(value.keyVersion, 1, Number.MAX_SAFE_INTEGER),
    nonce: base64(value.nonce, 12),
    ciphertext: base64(value.ciphertext, undefined, 512 * 1024),
    tag: base64(value.tag, 16),
  };
  if (value.schemaVersion !== undefined) result.schemaVersion = integer(value.schemaVersion, 1, 1000);
  if (value.aad !== undefined) result.aad = identifier(value.aad, 4096);
  return result;
}

export function parseLinuxCloudReplica(value: unknown): LinuxCloudRemoteReplica {
  if (!isRecord(value)) return invalid("Cloud replica must be an object.");
  exactKeys(value, [
    "domain",
    "recordID",
    "revision",
    "modifiedAtMillis",
    "sourceDeviceID",
    "tombstone",
  ], ["sealedPayload"]);
  const domain = identifier(value.domain, 64);
  if (!SUPPORTED_DOMAINS.has(domain)) return invalid("Cloud replica domain is unsupported.");
  if (typeof value.tombstone !== "boolean") return invalid("Cloud replica tombstone flag is invalid.");
  const sealedPayload = value.tombstone ? null : parseSealedPayload(value.sealedPayload);
  if (value.tombstone && value.sealedPayload !== null && value.sealedPayload !== undefined) {
    return invalid("A tombstone cannot contain ciphertext.");
  }
  const replica: LinuxCloudRemoteReplica = {
    domain,
    recordID: identifier(value.recordID),
    revision: integer(value.revision, 1, MAX_CURSOR),
    modifiedAtMillis: integer(value.modifiedAtMillis, 0, MAX_CURSOR),
    sourceDeviceID: identifier(value.sourceDeviceID),
    tombstone: value.tombstone,
    sealedPayload,
  };
  if (Buffer.byteLength(JSON.stringify(replica), "utf8") > MAX_REPLICA_BYTES) {
    return invalid("Cloud replica exceeds the supported size.");
  }
  return replica;
}

export function compareLinuxCloudReplicaOrder(a: LinuxCloudRemoteReplica, b: LinuxCloudRemoteReplica): number {
  if (a.revision !== b.revision) return a.revision < b.revision ? -1 : 1;
  if (a.modifiedAtMillis !== b.modifiedAtMillis) return a.modifiedAtMillis < b.modifiedAtMillis ? -1 : 1;
  if (a.sourceDeviceID === b.sourceDeviceID) return 0;
  return a.sourceDeviceID < b.sourceDeviceID ? -1 : 1;
}

export function authoritativeLinuxCloudReplica(
  existing: LinuxCloudRemoteReplica | undefined,
  candidate: LinuxCloudRemoteReplica,
): LinuxCloudRemoteReplica {
  return existing === undefined || compareLinuxCloudReplicaOrder(existing, candidate) < 0 ? candidate : existing;
}

function parseMutation(value: unknown): LinuxCloudOutboundMutation {
  if (!isRecord(value)) return invalid("Cloud replica mutation must be an object.");
  exactKeys(value, ["sequence", "mutationID", "replica"]);
  const sequence = integer(value.sequence, 1, MAX_CURSOR);
  const replica = parseLinuxCloudReplica(value.replica);
  const mutationID = identifier(value.mutationID, 4096);
  if (mutationID !== `${replica.sourceDeviceID}:${sequence}`) {
    return invalid("Cloud replica mutation id does not match its source and sequence.");
  }
  return { sequence, mutationID, replica };
}

export function parseLinuxCloudPushRequest(value: unknown): LinuxCloudOutboundMutation[] {
  if (!isRecord(value)) return invalid("Cloud replica push request must be an object.");
  exactKeys(value, ["mutations"]);
  if (!Array.isArray(value.mutations) || value.mutations.length === 0 || value.mutations.length > MAX_MUTATIONS) {
    return invalid("Cloud replica push batch size is invalid.");
  }
  if (Buffer.byteLength(JSON.stringify(value), "utf8") > 8 * 1024 * 1024) {
    return invalid("Cloud replica push request exceeds the supported size.");
  }
  const mutations = value.mutations.map(parseMutation);
  const ids = new Set(mutations.map((mutation) => mutation.mutationID));
  if (ids.size !== mutations.length) return invalid("Cloud replica mutation ids must be unique.");
  return mutations;
}

export function parseLinuxCloudCursor(value: unknown): number {
  if (value === undefined || value === null || value === "") return 0;
  if (typeof value !== "string" || !/^(0|[1-9][0-9]{0,15})$/.test(value)) {
    return invalid("Cloud replica cursor is invalid.");
  }
  return integer(Number(value), 0, MAX_CURSOR);
}

function replicaKey(replica: LinuxCloudRemoteReplica): string {
  return `${replica.domain}\0${replica.recordID}`;
}

function hashID(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

function mutationDigest(mutation: LinuxCloudOutboundMutation): string {
  return createHash("sha256").update(JSON.stringify(mutation)).digest("hex");
}

function replicaRef(uid: string, replica: LinuxCloudRemoteReplica): DocumentReference<DocumentData> {
  return db.doc(`users/${uid}/linux_cloud_replicas/${hashID(replicaKey(replica))}`);
}

function mutationRef(uid: string, mutationID: string): DocumentReference<DocumentData> {
  return db.doc(`users/${uid}/linux_cloud_sync_mutations/${hashID(mutationID)}`);
}

export const pushLinuxCloudReplicas = onCallProduction(
  "pushLinuxCloudReplicas",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, timeoutSeconds: 15, memory: "512MiB" },
  async (request) => {
    assertAuth(request);
    assertAppCheck(request);
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Firebase authentication is required.");
    const mutations = parseLinuxCloudPushRequest(request.data);

    return db.runTransaction(async (transaction) => {
      const stateRef = db.doc(`users/${uid}/linux_cloud_sync_state/replicas`);
      const uniqueReplicaRefs = new Map<string, DocumentReference<DocumentData>>();
      for (const mutation of mutations) uniqueReplicaRefs.set(replicaKey(mutation.replica), replicaRef(uid, mutation.replica));
      const idempotencyRefs = mutations.map((mutation) => mutationRef(uid, mutation.mutationID));
      const replicaRefs = [...uniqueReplicaRefs.values()];
      const snapshots = await transaction.getAll(stateRef, ...idempotencyRefs, ...replicaRefs);
      const byPath = new Map(snapshots.map((snapshot) => [snapshot.ref.path, snapshot]));
      const stateSnapshot = byPath.get(stateRef.path);
      const initialCursor = stateSnapshot?.exists ? integer(stateSnapshot.get("cursor"), 0, MAX_CURSOR) : 0;
      let cursor = initialCursor;

      const winners = new Map<string, LinuxCloudRemoteReplica>();
      for (const [key, ref] of uniqueReplicaRefs) {
        const snapshot = byPath.get(ref.path);
        if (snapshot?.exists) winners.set(key, parseLinuxCloudReplica(snapshot.data()?.replica));
      }

      const newMutations: LinuxCloudOutboundMutation[] = [];
      for (let index = 0; index < mutations.length; index += 1) {
        const mutation = mutations[index];
        const prior = byPath.get(idempotencyRefs[index].path);
        const digest = mutationDigest(mutation);
        if (prior?.exists) {
          if (prior.get("digest") !== digest) {
            throw new HttpsError("already-exists", "A mutation id was replayed with different content.");
          }
          continue;
        }
        newMutations.push(mutation);
        const key = replicaKey(mutation.replica);
        winners.set(key, authoritativeLinuxCloudReplica(winners.get(key), mutation.replica));
      }

      for (const [key, winner] of winners) {
        const ref = uniqueReplicaRefs.get(key);
        if (!ref) throw new HttpsError("internal", "Cloud replica transaction key mismatch.");
        const existingSnapshot = byPath.get(ref.path);
        const existing = existingSnapshot?.exists ? parseLinuxCloudReplica(existingSnapshot.data()?.replica) : undefined;
        if (existing === undefined || compareLinuxCloudReplicaOrder(existing, winner) < 0) {
          cursor += 1;
          if (cursor > MAX_CURSOR) throw new HttpsError("resource-exhausted", "Cloud replica cursor is exhausted.");
          transaction.set(ref, { replica: winner, updatedSequence: cursor, updatedAt: FieldValue.serverTimestamp() });
        }
      }
      for (const mutation of newMutations) {
        transaction.create(mutationRef(uid, mutation.mutationID), {
          digest: mutationDigest(mutation),
          createdAt: FieldValue.serverTimestamp(),
        });
      }
      if (cursor !== initialCursor) {
        transaction.set(stateRef, { cursor, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
      }

      return {
        acknowledgedMutationIDs: mutations.map((mutation) => mutation.mutationID),
        authoritativeReplicas: [...winners.values()],
      };
    });
  },
);

export const pullLinuxCloudReplicas = onCallProduction(
  "pullLinuxCloudReplicas",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, timeoutSeconds: 15, memory: "512MiB" },
  async (request) => {
    assertAuth(request);
    assertAppCheck(request);
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Firebase authentication is required.");
    if (!isRecord(request.data)) return invalid("Cloud replica pull request must be an object.");
    exactKeys(request.data, ["domains", "limit"], ["cursor"]);
    if (!Array.isArray(request.data.domains) || request.data.domains.length === 0) {
      return invalid("At least one cloud replica domain is required.");
    }
    const domains = request.data.domains.map((domain) => identifier(domain, 64));
    if (new Set(domains).size !== domains.length || domains.some((domain) => !SUPPORTED_DOMAINS.has(domain))) {
      return invalid("Cloud replica domains are invalid.");
    }
    const cursor = parseLinuxCloudCursor(request.data.cursor);
    const limit = integer(request.data.limit, 1, MAX_PULL_LIMIT);
    const snapshot = await db
      .collection(`users/${uid}/linux_cloud_replicas`)
      .where("updatedSequence", ">", cursor)
      .orderBy("updatedSequence", "asc")
      .limit(limit)
      .get();
    const allowedDomains = new Set(domains);
    const replicas: LinuxCloudRemoteReplica[] = [];
    let nextCursor = cursor;
    for (const document of snapshot.docs) {
      const sequence = integer(document.get("updatedSequence"), 1, MAX_CURSOR);
      nextCursor = sequence;
      const replica = parseLinuxCloudReplica(document.get("replica"));
      if (allowedDomains.has(replica.domain)) replicas.push(replica);
    }
    return { replicas, nextCursor: String(nextCursor) };
  },
);
