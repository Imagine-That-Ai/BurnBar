import { createHash, createPublicKey, randomBytes, verify as verifySignature } from "node:crypto";

import { Timestamp, type Firestore } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { GoogleAuth } from "google-auth-library";

import { providerFetch } from "../providers/httpClient.js";

export const LINUX_ATTESTATION_PROTOCOL_VERSION = 1 as const;
export const LINUX_ATTESTATION_KIND = "tpm2_ima_signed_verdict_v1" as const;
export const LINUX_ATTESTATION_POLICY_DEFAULT = "openburnbar-linux-tpm2-ima-v1" as const;
export const LINUX_ATTESTATION_CHALLENGE_TTL_MS = 2 * 60 * 1000;
export const LINUX_ATTESTATION_REPLAY_MARKER_TTL_MS = 24 * 60 * 60 * 1000;
export const LINUX_APP_CHECK_TOKEN_TTL_MS = 30 * 60 * 1000;

const MAX_DEVICE_ID_LENGTH = 160;
const MAX_APP_VERSION_LENGTH = 80;
const MAX_ARCHITECTURE_LENGTH = 24;
const MAX_POLICY_ID_LENGTH = 160;
const MAX_EVIDENCE_BYTES = 512 * 1024;
const MAX_VERDICT_BYTES = 64 * 1024;
const VERIFIER_REQUEST_TIMEOUT_MS = 60_000;
const SHA256_HEX = /^[a-f0-9]{64}$/u;
const SAFE_LABEL = /^[A-Za-z0-9._:+-]+$/u;
const BEARER_ID_TOKEN = /^Bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u;

export type LinuxAttestationRejectReason =
  | "malformed"
  | "challenge_missing"
  | "challenge_expired"
  | "challenge_replayed"
  | "binding_mismatch"
  | "verifier_unconfigured"
  | "verifier_unavailable"
  | "verdict_invalid"
  | "verdict_denied";

export interface LinuxAttestationBinding {
  uid: string;
  appId: string;
  deviceId: string;
  appVersion: string;
  architecture: string;
  releaseDigestSha256: string;
  policyId: string;
  attestationKind: string;
}

export interface LinuxAttestationChallenge extends LinuxAttestationBinding {
  challengeId: string;
  challenge: string;
  expiresAtMillis: number;
  protocolVersion: typeof LINUX_ATTESTATION_PROTOCOL_VERSION;
}

export interface LinuxAttestationEvidence {
  challengeId: string;
  challenge: string;
  kind: string;
  evidence: unknown;
}

export interface LinuxAttestationDecision extends LinuxAttestationBinding {
  trustClass: "linux_lower_trust";
  verifierReceiptHash: string;
  attestedAtMillis: number;
  expiresAtMillis: number;
}

export interface LinuxStoredAttestationChallenge extends LinuxAttestationBinding {
  protocolVersion: typeof LINUX_ATTESTATION_PROTOCOL_VERSION;
  challengeHashSha256: string;
  createdAtMillis: number;
  expiresAtMillis: number;
  consumedAtMillis?: number;
}

export interface LinuxAttestationChallengeStore {
  create(binding: LinuxAttestationBinding, nowMillis: number): Promise<LinuxAttestationChallenge>;
  load(uid: string, challengeId: string): Promise<LinuxStoredAttestationChallenge | undefined>;
  consume(uid: string, challengeId: string, expectedChallengeHash: string, nowMillis: number): Promise<void>;
}

export interface LinuxAttestationVerifier {
  readonly kind: string;
  verify(input: {
    challenge: LinuxAttestationChallenge;
    evidence: unknown;
    nowMillis: number;
  }): Promise<LinuxAttestationDecision>;
}

export interface LinuxVerifierIdentityTokenProvider {
  getAuthorizationHeader(): Promise<string>;
}

interface GoogleIdTokenAuthFactory {
  getIdTokenClient(targetAudience: string): Promise<{
    getRequestHeaders(): Promise<{ get(name: string): unknown }>;
  }>;
}

export class GoogleCloudRunIdentityTokenProvider implements LinuxVerifierIdentityTokenProvider {
  private clientPromise?: ReturnType<GoogleIdTokenAuthFactory["getIdTokenClient"]>;

  constructor(
    private readonly targetAudience: string,
    private readonly auth: GoogleIdTokenAuthFactory = new GoogleAuth(),
  ) {}

  private async client(): Promise<Awaited<ReturnType<GoogleIdTokenAuthFactory["getIdTokenClient"]>>> {
    const existing = this.clientPromise;
    if (existing) return existing;

    const pending = this.auth.getIdTokenClient(this.targetAudience);
    this.clientPromise = pending;
    try {
      return await pending;
    } catch (error) {
      if (this.clientPromise === pending) this.clientPromise = undefined;
      throw error;
    }
  }

  async getAuthorizationHeader(): Promise<string> {
    const headers = await (await this.client()).getRequestHeaders();
    const authorization = headers.get("authorization");
    if (typeof authorization !== "string" || !BEARER_ID_TOKEN.test(authorization)) {
      throw new Error("Google identity token client returned a malformed authorization header.");
    }
    return authorization;
  }
}

export function sha256Hex(value: string | Buffer): string {
  return createHash("sha256").update(value).digest("hex");
}

function boundedLabel(raw: unknown, field: string, maxLength: number): string {
  const value = typeof raw === "string" ? raw.trim() : "";
  if (!value || value.length > maxLength || !SAFE_LABEL.test(value)) {
    throw new HttpsError("invalid-argument", `${field} is malformed.`);
  }
  return value;
}

export function parseLinuxAttestationBinding(
  raw: unknown,
  expected: { uid: string; appId: string; policyId: string },
): LinuxAttestationBinding {
  if (raw == null || typeof raw !== "object") {
    throw new HttpsError("invalid-argument", "Linux attestation binding is required.");
  }
  const value = raw as Record<string, unknown>;
  const releaseDigestSha256 = typeof value.releaseDigestSha256 === "string" ? value.releaseDigestSha256.trim() : "";
  if (!SHA256_HEX.test(releaseDigestSha256)) {
    throw new HttpsError("invalid-argument", "releaseDigestSha256 must be lowercase SHA-256 hex.");
  }
  const appId = typeof value.appId === "string" ? value.appId.trim() : expected.appId;
  const policyId = typeof value.policyId === "string" ? value.policyId.trim() : expected.policyId;
  if (appId !== expected.appId || policyId !== expected.policyId) {
    throw new HttpsError("permission-denied", "Linux attestation policy binding does not match the server policy.");
  }
  return {
    uid: expected.uid,
    appId,
    deviceId: boundedLabel(value.deviceId, "deviceId", MAX_DEVICE_ID_LENGTH),
    appVersion: boundedLabel(value.appVersion, "appVersion", MAX_APP_VERSION_LENGTH),
    architecture: boundedLabel(value.architecture, "architecture", MAX_ARCHITECTURE_LENGTH),
    releaseDigestSha256,
    policyId: boundedLabel(policyId, "policyId", MAX_POLICY_ID_LENGTH),
    attestationKind: boundedLabel(value.attestationKind, "attestationKind", 80),
  };
}

function parseStoredChallenge(
  raw: FirebaseFirestore.DocumentData | undefined,
): LinuxStoredAttestationChallenge | undefined {
  if (!raw || raw.protocolVersion !== LINUX_ATTESTATION_PROTOCOL_VERSION) return undefined;
  const requiredStrings = [
    "uid",
    "appId",
    "deviceId",
    "appVersion",
    "architecture",
    "releaseDigestSha256",
    "policyId",
    "attestationKind",
    "challengeHashSha256",
  ] as const;
  for (const key of requiredStrings) {
    if (typeof raw[key] !== "string" || raw[key].length === 0) return undefined;
  }
  if (typeof raw.createdAtMillis !== "number" || typeof raw.expiresAtMillis !== "number") return undefined;
  return {
    protocolVersion: LINUX_ATTESTATION_PROTOCOL_VERSION,
    uid: raw.uid,
    appId: raw.appId,
    deviceId: raw.deviceId,
    appVersion: raw.appVersion,
    architecture: raw.architecture,
    releaseDigestSha256: raw.releaseDigestSha256,
    policyId: raw.policyId,
    attestationKind: raw.attestationKind,
    challengeHashSha256: raw.challengeHashSha256,
    createdAtMillis: raw.createdAtMillis,
    expiresAtMillis: raw.expiresAtMillis,
    consumedAtMillis: typeof raw.consumedAtMillis === "number" ? raw.consumedAtMillis : undefined,
  };
}

export class FirestoreLinuxAttestationChallengeStore implements LinuxAttestationChallengeStore {
  constructor(private readonly firestore: Firestore) {}

  async create(binding: LinuxAttestationBinding, nowMillis: number): Promise<LinuxAttestationChallenge> {
    const challengeId = randomBytes(24).toString("base64url");
    const challenge = randomBytes(32).toString("base64url");
    const expiresAtMillis = nowMillis + LINUX_ATTESTATION_CHALLENGE_TTL_MS;
    const ref = this.firestore.doc(`users/${binding.uid}/linux_app_check_challenges/${challengeId}`);
    await ref.create({
      protocolVersion: LINUX_ATTESTATION_PROTOCOL_VERSION,
      ...binding,
      challengeHashSha256: sha256Hex(challenge),
      createdAtMillis: nowMillis,
      expiresAtMillis,
      createdAt: Timestamp.fromMillis(nowMillis),
      expireAt: Timestamp.fromMillis(nowMillis + LINUX_ATTESTATION_REPLAY_MARKER_TTL_MS),
      consumedAtMillis: null,
    });
    return {
      ...binding,
      challengeId,
      challenge,
      expiresAtMillis,
      protocolVersion: LINUX_ATTESTATION_PROTOCOL_VERSION,
    };
  }

  async load(uid: string, challengeId: string): Promise<LinuxStoredAttestationChallenge | undefined> {
    const snap = await this.firestore.doc(`users/${uid}/linux_app_check_challenges/${challengeId}`).get();
    return snap.exists ? parseStoredChallenge(snap.data()) : undefined;
  }

  async consume(uid: string, challengeId: string, expectedChallengeHash: string, nowMillis: number): Promise<void> {
    const ref = this.firestore.doc(`users/${uid}/linux_app_check_challenges/${challengeId}`);
    await this.firestore.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const stored = snap.exists ? parseStoredChallenge(snap.data()) : undefined;
      if (!stored || stored.challengeHashSha256 !== expectedChallengeHash) {
        throw linuxAttestationError("challenge_missing");
      }
      if (stored.expiresAtMillis < nowMillis) throw linuxAttestationError("challenge_expired");
      if (stored.consumedAtMillis != null) throw linuxAttestationError("challenge_replayed");
      tx.update(ref, {
        consumedAtMillis: nowMillis,
        consumedAt: Timestamp.fromMillis(nowMillis),
      });
    });
  }
}

export function assertChallengeBinding(
  stored: LinuxStoredAttestationChallenge,
  challenge: string,
  nowMillis: number,
): LinuxAttestationChallenge {
  if (stored.consumedAtMillis != null) throw linuxAttestationError("challenge_replayed");
  if (stored.expiresAtMillis < nowMillis) throw linuxAttestationError("challenge_expired");
  if (sha256Hex(challenge) !== stored.challengeHashSha256) throw linuxAttestationError("challenge_missing");
  return {
    uid: stored.uid,
    appId: stored.appId,
    deviceId: stored.deviceId,
    appVersion: stored.appVersion,
    architecture: stored.architecture,
    releaseDigestSha256: stored.releaseDigestSha256,
    policyId: stored.policyId,
    attestationKind: stored.attestationKind,
    challengeId: "",
    challenge,
    expiresAtMillis: stored.expiresAtMillis,
    protocolVersion: LINUX_ATTESTATION_PROTOCOL_VERSION,
  };
}

function linuxAttestationError(reason: LinuxAttestationRejectReason): HttpsError {
  const messages: Record<LinuxAttestationRejectReason, string> = {
    malformed: "Linux attestation evidence is malformed.",
    challenge_missing: "Linux attestation challenge is missing or does not match.",
    challenge_expired: "Linux attestation challenge expired.",
    challenge_replayed: "Linux attestation challenge was already consumed.",
    binding_mismatch: "Linux attestation verdict binding does not match the challenge.",
    verifier_unconfigured: "Linux production attestation verifier is not configured.",
    verifier_unavailable: "Linux production attestation verifier is unavailable.",
    verdict_invalid: "Linux attestation verifier returned an invalid verdict.",
    verdict_denied: "Linux attestation verifier denied this host.",
  };
  const code =
    reason === "malformed"
      ? "invalid-argument"
      : reason === "verifier_unavailable"
        ? "unavailable"
        : "permission-denied";
  return new HttpsError(code, messages[reason], { reason });
}

interface SignedLinuxVerdictEnvelope {
  algorithm: "Ed25519";
  keyId: string;
  verdict: LinuxAttestationDecision & {
    v: typeof LINUX_ATTESTATION_PROTOCOL_VERSION;
    issuer: string;
    audience: string;
    decision: "allow" | "deny";
    challengeId: string;
    challengeHashSha256: string;
  };
  signatureBase64: string;
}

type SignedLinuxVerdict = SignedLinuxVerdictEnvelope["verdict"];

function canonicalVerdict(verdict: SignedLinuxVerdictEnvelope["verdict"]): string {
  return [
    verdict.v,
    verdict.issuer,
    verdict.audience,
    verdict.decision,
    verdict.uid,
    verdict.appId,
    verdict.deviceId,
    verdict.appVersion,
    verdict.architecture,
    verdict.releaseDigestSha256,
    verdict.policyId,
    verdict.attestationKind,
    verdict.challengeId,
    verdict.challengeHashSha256,
    verdict.trustClass,
    verdict.verifierReceiptHash,
    verdict.attestedAtMillis,
    verdict.expiresAtMillis,
  ].join("\n");
}

function exactDecisionBinding(decision: LinuxAttestationDecision, challenge: LinuxAttestationChallenge): boolean {
  return (
    decision.uid === challenge.uid &&
    decision.appId === challenge.appId &&
    decision.deviceId === challenge.deviceId &&
    decision.appVersion === challenge.appVersion &&
    decision.architecture === challenge.architecture &&
    decision.releaseDigestSha256 === challenge.releaseDigestSha256 &&
    decision.policyId === challenge.policyId &&
    decision.attestationKind === challenge.attestationKind &&
    decision.trustClass === "linux_lower_trust"
  );
}

async function readBoundedResponse(response: Response, maximumBytes: number): Promise<Buffer> {
  const declaredLength = response.headers.get("content-length");
  if (declaredLength) {
    const parsed = Number(declaredLength);
    if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > maximumBytes) {
      throw linuxAttestationError("verdict_invalid");
    }
  }
  if (!response.body) return Buffer.alloc(0);
  const reader = response.body.getReader();
  const chunks: Buffer[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maximumBytes) {
        await reader.cancel();
        throw linuxAttestationError("verdict_invalid");
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock();
  }
  return Buffer.concat(chunks, total);
}

function normalizeBoundedEvidence(evidence: unknown): unknown {
  const encoded = JSON.stringify(evidence);
  if (!encoded || Buffer.byteLength(encoded) > MAX_EVIDENCE_BYTES) {
    throw linuxAttestationError("malformed");
  }
  return JSON.parse(encoded) as unknown;
}

function abortable<T>(operation: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) return Promise.reject(signal.reason);
  return new Promise<T>((resolve, reject) => {
    const handleAbort = (): void => reject(signal.reason);
    signal.addEventListener("abort", handleAbort, { once: true });
    if (signal.aborted) {
      handleAbort();
      return;
    }
    operation.then(
      (value) => {
        signal.removeEventListener("abort", handleAbort);
        resolve(value);
      },
      (error: unknown) => {
        signal.removeEventListener("abort", handleAbort);
        reject(error);
      },
    );
  });
}

function parseSignedVerdict(body: Buffer): SignedLinuxVerdictEnvelope {
  if (body.length === 0 || body.length > MAX_VERDICT_BYTES) throw linuxAttestationError("verdict_invalid");
  try {
    return JSON.parse(body.toString("utf8")) as SignedLinuxVerdictEnvelope;
  } catch {
    throw linuxAttestationError("verdict_invalid");
  }
}

function isValidVerdictContext(
  verdict: SignedLinuxVerdict | undefined,
  input: { challenge: LinuxAttestationChallenge; nowMillis: number },
  configuration: { issuer: string; audience: string },
): verdict is SignedLinuxVerdict {
  return (
    verdict?.v === LINUX_ATTESTATION_PROTOCOL_VERSION &&
    verdict.issuer === configuration.issuer &&
    verdict.audience === configuration.audience &&
    verdict.decision === "allow" &&
    verdict.challengeId === input.challenge.challengeId &&
    verdict.challengeHashSha256 === sha256Hex(input.challenge.challenge) &&
    exactDecisionBinding(verdict, input.challenge) &&
    SHA256_HEX.test(verdict.verifierReceiptHash) &&
    verdict.attestedAtMillis <= input.nowMillis + 60_000 &&
    verdict.expiresAtMillis >= input.nowMillis &&
    verdict.expiresAtMillis <= input.nowMillis + LINUX_ATTESTATION_CHALLENGE_TTL_MS
  );
}

function assertValidSignedVerdict(
  envelope: SignedLinuxVerdictEnvelope,
  input: { challenge: LinuxAttestationChallenge; nowMillis: number },
  configuration: { keyId: string; issuer: string; audience: string },
): { verdict: SignedLinuxVerdict; signature: Buffer } {
  const verdict = envelope?.verdict;
  const signature =
    typeof envelope?.signatureBase64 === "string" ? Buffer.from(envelope.signatureBase64, "base64") : Buffer.alloc(0);
  if (
    envelope?.algorithm !== "Ed25519" ||
    envelope?.keyId !== configuration.keyId ||
    !isValidVerdictContext(verdict, input, configuration) ||
    signature.length !== 64
  ) {
    throw linuxAttestationError("verdict_invalid");
  }
  return { verdict, signature };
}

export class RemoteSignedLinuxAttestationVerifier implements LinuxAttestationVerifier {
  readonly kind = LINUX_ATTESTATION_KIND;
  private readonly publicKey: ReturnType<typeof createPublicKey>;
  private readonly identityTokenProvider: LinuxVerifierIdentityTokenProvider;
  private readonly endpoint: URL;

  constructor(
    private readonly configuration: {
      endpoint: URL;
      oidcAudience: string;
      publicKeyBase64: string;
      keyId: string;
      issuer: string;
      audience: string;
      identityTokenProvider?: LinuxVerifierIdentityTokenProvider;
    },
  ) {
    const endpoint = new URL(configuration.endpoint.href);
    if (
      endpoint.protocol !== "https:" ||
      endpoint.username !== "" ||
      endpoint.password !== "" ||
      endpoint.search !== "" ||
      endpoint.hash !== "" ||
      configuration.oidcAudience !== endpoint.origin
    ) {
      throw linuxAttestationError("verifier_unconfigured");
    }
    try {
      this.publicKey = createPublicKey({
        key: Buffer.from(configuration.publicKeyBase64, "base64"),
        format: "der",
        type: "spki",
      });
      if (this.publicKey.asymmetricKeyType !== "ed25519") throw new Error("wrong key type");
    } catch {
      throw linuxAttestationError("verifier_unconfigured");
    }
    this.endpoint = endpoint;
    this.identityTokenProvider =
      configuration.identityTokenProvider ?? new GoogleCloudRunIdentityTokenProvider(configuration.oidcAudience);
  }

  async verify(input: {
    challenge: LinuxAttestationChallenge;
    evidence: unknown;
    nowMillis: number;
  }): Promise<LinuxAttestationDecision> {
    const evidence = normalizeBoundedEvidence(input.evidence);
    const requestSignal = AbortSignal.timeout(VERIFIER_REQUEST_TIMEOUT_MS);
    let authorization: string;
    try {
      authorization = await abortable(this.identityTokenProvider.getAuthorizationHeader(), requestSignal);
      if (!BEARER_ID_TOKEN.test(authorization)) throw new Error("malformed identity token");
    } catch {
      throw linuxAttestationError("verifier_unavailable");
    }
    let response: Response;
    try {
      response = await providerFetch("linux-attestation", "verify", this.endpoint, {
        method: "POST",
        headers: {
          Authorization: authorization,
          "content-type": "application/json",
          "cache-control": "no-store",
        },
        body: JSON.stringify({ challenge: input.challenge, evidence }),
        redirect: "error",
        signal: requestSignal,
      });
    } catch {
      throw linuxAttestationError("verifier_unavailable");
    }
    if (!response.ok) {
      if (response.status >= 500 || response.status === 429) throw linuxAttestationError("verifier_unavailable");
      throw linuxAttestationError("verdict_denied");
    }
    const envelope = parseSignedVerdict(await readBoundedResponse(response, MAX_VERDICT_BYTES));
    const { verdict, signature } = assertValidSignedVerdict(envelope, input, this.configuration);
    if (!verifySignature(null, Buffer.from(canonicalVerdict(verdict), "utf8"), this.publicKey, signature)) {
      throw linuxAttestationError("verdict_invalid");
    }
    return verdict;
  }
}

export function parseLinuxAttestationEvidence(raw: unknown): LinuxAttestationEvidence {
  if (raw == null || typeof raw !== "object") throw linuxAttestationError("malformed");
  const value = raw as Record<string, unknown>;
  const challengeId = boundedLabel(value.challengeId, "challengeId", 80);
  const challenge = boundedLabel(value.challenge, "challenge", 128);
  const kind = boundedLabel(value.kind, "kind", 80);
  if (value.evidence == null) throw linuxAttestationError("malformed");
  return { challengeId, challenge, kind, evidence: value.evidence };
}

export const __testing__ = {
  canonicalVerdict,
  exactDecisionBinding,
  readBoundedResponse,
  abortable,
  linuxAttestationError,
  parseStoredChallenge,
};
