import type { Firestore } from "firebase-admin/firestore";

import { isRecord } from "./guards.js";

export interface CloudSearchManifest {
  schemaVersion: number;
  indexVersion: number;
  activeCommitIDsByDevice: Record<string, string>;
  latestCommittedAt?: string;
  documentCount: number;
  chunkCount: number;
  tokenPostingCount: number;
  semanticPostingCount: number;
  stale: boolean;
  compactionStatus?: string;
}

export function isCloudSearchHash(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{32,128}$/u.test(value);
}

export function boundedCloudSearchHashes(raw: unknown, max: number): string[] {
  if (!Array.isArray(raw)) return [];
  return raw.filter(isCloudSearchHash).slice(0, max);
}

function parseStringRecord(raw: unknown): Record<string, string> {
  if (!isRecord(raw)) return {};
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(raw)) {
    if (typeof value === "string") out[key] = value;
  }
  return out;
}

export async function readCloudSearchManifest(db: Firestore, uid: string): Promise<CloudSearchManifest> {
  const current = await db.doc(`users/${uid}/cloud_search_index_manifest/current`).get();
  if (current.exists) {
    const data = current.data() ?? {};
    return {
      schemaVersion: Number(data.schemaVersion ?? 1),
      indexVersion: Number(data.indexVersion ?? 1),
      activeCommitIDsByDevice: parseStringRecord(data.activeCommitIDsByDevice),
      latestCommittedAt: typeof data.latestCommittedAt === "string" ? data.latestCommittedAt : undefined,
      documentCount: Number(data.documentCount ?? 0),
      chunkCount: Number(data.chunkCount ?? 0),
      tokenPostingCount: Number(data.tokenPostingCount ?? 0),
      semanticPostingCount: Number(data.semanticPostingCount ?? 0),
      stale: data.stale === true,
      compactionStatus: typeof data.compactionStatus === "string" ? data.compactionStatus : undefined
    };
  }
  const states = await db.collection(`users/${uid}/cloud_search_index_state`).limit(100).get();
  const activeCommitIDsByDevice: Record<string, string> = {};
  let documentCount = 0;
  let chunkCount = 0;
  for (const state of states.docs) {
    const commitID = state.get("activeCommitID");
    if (typeof commitID === "string") activeCommitIDsByDevice[state.id] = commitID;
    documentCount += Number(state.get("documentCount") ?? 0);
    chunkCount += Number(state.get("chunkCount") ?? 0);
  }
  return {
    schemaVersion: 1,
    indexVersion: 1,
    activeCommitIDsByDevice,
    documentCount,
    chunkCount,
    tokenPostingCount: 0,
    semanticPostingCount: 0,
    stale: states.empty,
    compactionStatus: "legacy_index_state"
  };
}
