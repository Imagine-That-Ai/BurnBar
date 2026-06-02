/**
 * Typed wrappers over the BurnBar console callables (Firebase onCall, us-central1,
 * App Check enforced, auth-gated). Shapes mirror the CALLABLE API CONTRACT exactly;
 * the UI binds to these names so a server-side rename surfaces as a type error here.
 */
import { httpsCallable, type HttpsCallableResult } from "firebase/functions";
import { functions } from "./firebaseClient";
import type { EncryptionTier } from "./domains";

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
export interface DataDomainUsageResponse {
  ok: boolean;
  tier: "ultra" | "pro" | "free";
  limits: { pensieve: PensieveLimits };
  domains: DomainUsage[];
  schemaVersion: 1;
}
export const getDataDomainUsage = () =>
  call<void, DataDomainUsageResponse>("getDataDomainUsage");

// ── exportUserData ──────────────────────────────────────────────────────────
export interface SealedRef {
  path: string;
  bodyHash: string;
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
  schemaVersion: 1;
}
export const exportUserData = (domains?: string[]) =>
  call<{ domains?: string[] }, ExportUserDataResponse>("exportUserData", { domains });

// ── deleteDomainData ────────────────────────────────────────────────────────
export interface DeleteDomainDataResponse {
  ok: boolean;
  domainId: string;
  deleted: { firestoreDocs: number; storageObjects: number };
}
export const deleteDomainData = (domainId: string) =>
  call<{ domainId: string; confirm: true }, DeleteDomainDataResponse>("deleteDomainData", {
    domainId,
    confirm: true,
  });

// ── Recovery (forced before zero-knowledge mode) ────────────────────────────
export const setupRecovery = (
  method: "recovery_key" | "recovery_contact",
  payload: Record<string, unknown>,
) => call<{ method: typeof method; payload: typeof payload }, { ok: boolean; recoveryId: string }>(
  "setupRecovery",
  { method, payload },
);
export const confirmRecovery = (recoveryId: string) =>
  call<{ recoveryId: string }, { ok: boolean }>("confirmRecovery", { recoveryId });
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
  status: "pending";
}
export const registerBrowserEscrowDevice = (publicKeyJwk: JsonWebKey, recaptchaToken: string) =>
  call<{ publicKeyJwk: JsonWebKey; recaptchaToken: string }, RegisterBrowserEscrowResponse>(
    "registerBrowserEscrowDevice",
    { publicKeyJwk, recaptchaToken },
  );

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
