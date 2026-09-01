/**
 * Typed wrappers over the BurnBar console callables (Firebase onCall, us-central1,
 * App Check enforced, auth-gated). Shapes mirror the CALLABLE API CONTRACT exactly;
 * the UI binds to these names so a server-side rename surfaces as a type error here.
 */
import { httpsCallable, type HttpsCallableResult } from "firebase/functions";
import { functions } from "./firebaseClient";
import type { EncryptionTier } from "./domains";
import type { CloudVaultSealedText } from "./escrow";
import type {
  AuthenticationResponseJSON,
  PublicKeyCredentialRequestOptionsJSON,
  PublicKeyCredentialCreationOptionsJSON,
  RegistrationResponseJSON,
} from "@simplewebauthn/browser";

async function call<Req, Res>(name: string, payload?: Req): Promise<Res> {
  const fn = httpsCallable<Req, Res>(functions(), name);
  const res: HttpsCallableResult<Res> = await fn(payload as Req);
  return res.data;
}

// ── getDataDomainUsage ──────────────────────────────────────────────────────
export interface PensieveLimits {
  sources: number;
  chunks: number;
  bytes: number;
}
export interface DomainUsage {
  id: string;
  count: number;
  bytes: number;
}
export interface CloudProfileSummary {
  state: "published" | "missing";
  displayName?: string;
  avatarURL?: string;
  sourceDeviceId?: string;
  updatedAt?: string;
}
export interface ConsoleAccountSummary {
  profile: CloudProfileSummary;
  hasPublishedData: boolean;
  totalCount: number;
  totalBytes: number;
}
export type DataTier = "ultra" | "pro" | "free";
export interface DataDomainUsageResponse {
  ok: boolean;
  tier: DataTier;
  account?: ConsoleAccountSummary;
  limits: { pensieve: PensieveLimits };
  domains: DomainUsage[];
  schemaVersion: 1;
}
export const getDataDomainUsage = () =>
  call<void, DataDomainUsageResponse>("getDataDomainUsage");

// ── rebuildUsageRollups ─────────────────────────────────────────────────────
// Recomputes the member's usage_rollups server-side before a fresh read.
// `force: true` rebuilds even when the rollup job reports clean.
export interface RebuildUsageRollupsResponse {
  ok?: boolean;
  computedAt?: string;
}
export const rebuildUsageRollups = (force = false) =>
  call<{ force?: boolean }, RebuildUsageRollupsResponse>("rebuildUsageRollups", { force });

// ── Pensieve connected repos ────────────────────────────────────────────────
// A connected repo stores only an opaque keyed match token + a vault-sealed
// `sealedRepoFullName`; the cleartext name is observed transiently server-side
// to compute the webhook match token and is NEVER stored. The console decrypts
// `sealedRepoFullName` locally for display.
export interface KnowledgeRepoSummary {
  repoId: string;
  sealedRepoFullName: CloudVaultSealedText | null;
  /**
   * Legacy field kept for response-shape back-compat: ALWAYS null now. The
   * cleartext repo-name-derived slug is no longer stored or echoed; the server
   * routes manifests on the opaque `sourceSlugToken` instead (§4 slug remediation).
   */
  sourceSlug: string | null;
  /** Opaque, server-keyed manifest routing token (replaces cleartext sourceSlug). */
  sourceSlugToken: string | null;
  installId: string | null;
  connectedAt: string | null;
  chunkCount: number;
  byteCount: number;
  lastSyncAt: string | null;
  lastDirtyAt: string | null;
  needsResync: boolean;
}
export const listKnowledgeRepos = () =>
  call<void, { ok: boolean; repos: KnowledgeRepoSummary[] }>("listKnowledgeRepos");

export interface ConnectKnowledgeRepoRequest {
  /** Cleartext `owner/name` — sent transiently for the webhook match token, never stored. */
  repoFullName: string;
  /** Vault-sealed display name; the only repo-name form the server persists. */
  sealedRepoFullName: CloudVaultSealedText;
  sourceSlug: string;
}
export const connectKnowledgeRepo = (payload: ConnectKnowledgeRepoRequest) =>
  call<ConnectKnowledgeRepoRequest, { ok: boolean; repoId: string }>("connectKnowledgeRepo", payload);

export const disconnectKnowledgeRepo = (repoId: string) =>
  call<{ repoId: string }, { ok: boolean }>("disconnectKnowledgeRepo", { repoId });

/** Queue a re-sync of every connected repo (flags manifests for the Mac daemon). */
export const requestKnowledgeResync = () =>
  call<void, { ok: boolean; flagged: number }>("requestKnowledgeResync");

// ── exportUserData ──────────────────────────────────────────────────────────
export interface SealedRef {
  pathDigest: string;
  signedUrl: string;
}
export interface ExportedDomain {
  id: string;
  encryptionTier: EncryptionTier;
  inlineJson?: Record<string, unknown>;
  sealedRefs?: SealedRef[];
}
export interface ExportUserDataResponse {
  ok: boolean;
  generatedAt: string;
  domains: ExportedDomain[];
  schemaVersion: 2;
}
export const exportUserData = (domains?: string[]) =>
  call<{ domains?: string[] }, ExportUserDataResponse>("exportUserData", { domains });

// ── deleteDomainData ────────────────────────────────────────────────────────
export interface DeleteDomainDataResponse {
  ok: boolean;
  domainId: string;
  deleted: { firestoreDocs: number; storageObjects: number };
}

/**
 * Shown wherever the console has to explain that per-domain deletion cannot be
 * completed from the web. Keep in sync with the trusted-device step-up gate on
 * the `deleteDomainData` callable (functions/src/callables/dataDeletion.ts).
 */
export const DOMAIN_DELETE_TRUSTED_DEVICE_MESSAGE =
  "Deleting this data requires approval from a trusted device. Open BurnBar on one of " +
  "your trusted devices to complete the deletion — the web console cannot provide the " +
  "required device proof.";

/**
 * Server-side, `deleteDomainData` is step-up gated: it demands a fresh
 * high-risk nonce plus a trusted-device action proof, and this web surface can
 * produce neither. The console UI therefore never invokes this wrapper (see
 * DeleteDomainDialog); it stays for typed-contract parity, and any residual
 * caller gets the actionable trusted-device message instead of the raw
 * `failed-precondition` gate error.
 */
export const deleteDomainData = async (domainId: string): Promise<DeleteDomainDataResponse> => {
  try {
    return await call<{ domainId: string; confirm: true }, DeleteDomainDataResponse>(
      "deleteDomainData",
      { domainId, confirm: true },
    );
  } catch (err) {
    const code = (err as { code?: unknown }).code;
    const message = err instanceof Error ? err.message : "";
    const isStepUpRejection =
      (code === "functions/failed-precondition" || code === "functions/permission-denied") &&
      /high-risk|trusted-device|nonce/i.test(message);
    if (isStepUpRejection) {
      throw new Error(DOMAIN_DELETE_TRUSTED_DEVICE_MESSAGE);
    }
    throw err;
  }
};

// ── Recovery (forced before zero-knowledge mode) ────────────────────────────
export const setupRecovery = (
  method: "recovery_key" | "recovery_contact",
  payload: Record<string, unknown>,
) => call<{ method: typeof method; payload: typeof payload }, { ok: boolean; recoveryId: string }>(
  "setupRecovery",
  { method, payload },
);
// recovery_key methods require re-verification: the client re-derives the key's
// verificationHash and passes it so the server can prove the user re-entered the
// key (Apple ADP delayed-confirm). recovery_contact methods omit it.
export const confirmRecovery = (recoveryId: string, verificationHash?: string) => {
  const payload: { recoveryId: string; verificationHash?: string } = { recoveryId };
  if (typeof verificationHash === "string") {
    payload.verificationHash = verificationHash;
  }
  return call<typeof payload, { ok: boolean }>("confirmRecovery", payload);
};
export interface RecoveryMethod {
  recoveryId: string;
  kind: string;
  createdAt: string;
  confirmed: boolean;
}
export const listRecovery = () =>
  call<void, { ok: boolean; methods: RecoveryMethod[] }>("listRecovery");

// ── revokeAllAccess (PANIC) ─────────────────────────────────────────────────
export interface RevokeAllAccessResponse {
  ok: boolean;
  revoked: {
    mcpClients: number;
    devices: number;
    escrowDevices: number;
    providers: number;
  };
}
export const revokeAllAccess = (scope: "sync" | "all") =>
  call<{ scope: typeof scope }, RevokeAllAccessResponse>("revokeAllAccess", { scope });

// ── Audit log (tamper-evident hash chain) ───────────────────────────────────
export interface AuditEvent {
  seq: number;
  ts: string;
  actor: string;
  action: string;
  domain: string;
  prevHash: string;
  hash: string;
}
export interface AuditLogResponse {
  ok: boolean;
  events: AuditEvent[];
  nextCursor?: string;
}
export const getAuditLog = (cursor?: string, limit?: number) =>
  call<{ cursor?: string; limit?: number }, AuditLogResponse>("getAuditLog", { cursor, limit });
export const verifyAuditLog = () =>
  call<void, { ok: boolean; valid: boolean; brokenAt?: number }>("verifyAuditLog");

// ── Browser escrow registration ─────────────────────────────────────────────
export interface RegisterBrowserEscrowResponse {
  ok: boolean;
  escrowDeviceId: string;
  status: "pending" | "trusted";
}
export const registerBrowserEscrowDevice = (publicKeyJwk: JsonWebKey) =>
  call<{ publicKeyJwk: JsonWebKey }, RegisterBrowserEscrowResponse>("registerBrowserEscrowDevice", { publicKeyJwk });

/**
 * Poll an escrow device for trusted-device approval. The native device approves
 * via approveEscrowDeviceTrust, minting a cloud_vault_key_wrapper. There is no
 * dedicated "get my wrapper" callable in the documented contract, so the console
 * reads the wrapper through exportUserData(device_trust_keys) sealedRefs/inlineJson.
 * Surfaced here as a thin status type the escrow flow consumes.
 */
export interface EscrowApprovalStatus {
  status: "pending" | "approved" | "revoked";
  /** Base64 (Swift x963||combined) wrapped vault key, present once approved. */
  wrappedKeyBase64?: string;
}

// ── Pensieve recall (client embeds+cloaks, server ANN-searches opaque vectors) ─
export interface SearchKnowledgeHit {
  vectorId: string;
  ciphertext: unknown;
  sealedMetadata: unknown;
  sourceKind: "repo_docs" | "notes" | "chat_memory";
  sourceSlug: string;
  contentHash: string;
  score: number;
  decryptMode: "local_decrypt";
}
export interface SearchKnowledgeResponse {
  ok: boolean;
  hits: SearchKnowledgeHit[];
  embeddingModelVersion: string;
}
export const searchKnowledge = (payload: {
  queryVector: number[];
  embeddingModelVersion: string;
  sourceKind?: "repo_docs" | "notes" | "chat_memory";
  sourceSlug?: string;
  limit?: number;
}) => call<typeof payload, SearchKnowledgeResponse>("searchKnowledge", payload);

export interface KnowledgeChunkItem {
  vectorId: string;
  ciphertext: unknown;
  sealedMetadata: unknown;
  signalEnvelope?: unknown;
  sourceKind: string;
  slugHmac?: string;
  dedupHash?: string;
  byteCount: number;
  updatedAtMillis: number;
}

export interface ListKnowledgeChunksResponse {
  ok: boolean;
  chunks: KnowledgeChunkItem[];
  hasMore: boolean;
  nextStartAfterId: string | null;
}

export const listKnowledgeChunks = (payload?: {
  sourceKind?: string;
  slugHmac?: string;
  limit?: number;
  startAfterId?: string;
}) => call<typeof payload, ListKnowledgeChunksResponse>("listKnowledgeChunks", payload ?? {});

// ── Passkeys ───────────────────────────────────────────────────────────────
export const registerPasskey = () =>
  call<void, { ok: boolean; options: PublicKeyCredentialCreationOptionsJSON }>("registerPasskey");
export const verifyPasskeyRegistration = (response: RegistrationResponseJSON, challenge: string) =>
  call<
    { response: RegistrationResponseJSON; challenge: string },
    { ok: boolean; credentialId: string }
  >("verifyPasskeyRegistration", { response, challenge });
export const beginPasskeyAssertion = () =>
  call<void, { ok: boolean; options: PublicKeyCredentialRequestOptionsJSON }>("beginPasskeyAssertion");
export const verifyPasskeyAssertion = (assertion: AuthenticationResponseJSON, challenge: string) =>
  call<
    { assertion: AuthenticationResponseJSON; challenge: string },
    { ok: boolean; token: string }
  >("verifyPasskeyAssertion", { assertion, challenge });
