/** Mission dispatch and approval policy contracts. */
namespace OpenBurnBar.Firestore.Missions;

model MissionDispatchDoc {
  missionId: string;
  status: string;
  createdAt: string;
  updatedAt?: string;
  payloadSummary?: string;
}

model ApprovalPolicyDoc {
  policyVersion: int32;
  updatedAt: string;
}

/**
 * Census row for executable/mission runtimes. Source of truth is
 * tools/schema-sync/fixtures/mission-runtime-catalog.json; this model is the
 * TypeSpec shape of that fixture. A catalog row is not a launch path.
 */
model MissionRuntimeCatalogRow {
  id: string;
  wireAliases: string[];
  displayName: string;
  surfaces: string[];
  launch: "none" | "argv" | "acp";
  platforms: string[];
}

/** Cloud file-plane metadata. Ciphertext lives in Storage; this doc is courier metadata. */
model BurnbarAttachmentDoc {
  id: string;
  contentBlake3: string;
  byteCount: int64;
  chunkCount: int32;
  transport: "p2p" | "cloud";
  state: "pending_upload" | "composing" | "uploaded" | "expired" | "deleted";
  storagePath: string;
  storageGeneration?: string;
  meteredBytes?: int64;
  reservedBytes?: int64;
  createdAt: string;
  updatedAt: string;
}
