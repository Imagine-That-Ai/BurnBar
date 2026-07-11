/**
 * Linux Firebase App Check custom-provider bootstrap.
 *
 * Production minting is disabled by default. When enabled, the client must
 * first obtain a durable, UID-bound challenge and present evidence accepted by
 * the pinned remote TPM/IMA verifier. The mock verifier is test/emulator only.
 */

import { createHash, timingSafeEqual } from "node:crypto";

import { getAppCheck, type AppCheckToken, type AppCheckTokenOptions } from "firebase-admin/app-check";
import { Timestamp } from "firebase-admin/firestore";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "../adminRuntime.js";
import { assertAuth } from "../auth.js";
import { getConfig, isAppCheckAppIdAllowed, PLACEHOLDER_LINUX_APP_CHECK_APP_ID } from "../config.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import {
  FirestoreLinuxAttestationChallengeStore,
  FirestoreLinuxAttestationEnrollmentTrustStore,
  LINUX_APP_CHECK_TOKEN_TTL_MS,
  LINUX_ATTESTATION_KIND,
  LINUX_ATTESTATION_POLICY_DEFAULT,
  RemoteSignedLinuxAttestationVerifier,
  assertChallengeBinding,
  parseLinuxAttestationBinding,
  parseLinuxAttestationEvidence,
  sha256Hex,
  type LinuxAttestationBinding,
  type LinuxAttestationChallenge,
  type LinuxAttestationChallengeStore,
  type LinuxAttestationDecision,
  type LinuxAttestationEnrollmentTrustStore,
  type LinuxAttestationVerifier,
  type LinuxVerifierIdentityTokenProvider,
} from "../security/linuxAttestation.js";
import {
  FirestoreLinuxAttestationTicketAuthority,
  parseLinuxEnrollmentTicketRequest,
  parseLinuxUploadTicketRequest,
} from "../security/linuxAttestationIngressTickets.js";
import { parseCallableInput } from "../validation/callableSchema.js";
import { checkPublicHttpEndpointRateLimit } from "./publicRateLimit.js";

const MOCK_ATTESTATION_KIND = "mock" as const;
const MOCK_ATTESTATION_DOMAIN = "openburnbar.appcheck.linux.mock.v2";
const MOCK_ATTESTATION_SHARED_SECRET = "openburnbar-linux-appcheck-mock-fixture-secret";
const REAL_FIREBASE_WEB_APP_ID = /^1:[0-9]+:web:[A-Za-z0-9]+$/u;

export type AppCheckTokenMinter = (appId: string, options?: AppCheckTokenOptions) => Promise<AppCheckToken>;

interface LinuxAppCheckRuntimePolicy {
  mintEnabled: boolean;
  appId: string;
  policyId: string;
  verifierURL?: URL;
  verifierOIDCAudience?: string;
  verifierPublicKeyBase64?: string;
  verifierKeyID?: string;
  verifierIssuer?: string;
  verifierAudience?: string;
}

interface MockEvidence {
  mac: string;
}

function mockMac(challenge: LinuxAttestationChallenge, secret = MOCK_ATTESTATION_SHARED_SECRET): string {
  const payload = [
    MOCK_ATTESTATION_DOMAIN,
    challenge.uid,
    challenge.appId,
    challenge.deviceId,
    challenge.appVersion,
    challenge.architecture,
    challenge.releaseDigestSha256,
    challenge.policyId,
    challenge.challengeId,
    challenge.challenge,
    secret,
  ].join("|");
  return createHash("sha256").update(payload).digest("hex");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  return timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

class MockLinuxAttestationVerifier implements LinuxAttestationVerifier {
  readonly kind = MOCK_ATTESTATION_KIND;

  constructor(private readonly sharedSecret = MOCK_ATTESTATION_SHARED_SECRET) {}

  async verify(input: {
    challenge: LinuxAttestationChallenge;
    evidence: unknown;
    nowMillis: number;
  }): Promise<LinuxAttestationDecision> {
    const raw = input.evidence as Partial<MockEvidence> | null;
    const mac = raw && typeof raw.mac === "string" ? raw.mac : "";
    if (!constantTimeEqual(mac, mockMac(input.challenge, this.sharedSecret))) {
      throw new HttpsError("unauthenticated", "Linux fixture attestation signature did not verify.");
    }
    return {
      uid: input.challenge.uid,
      appId: input.challenge.appId,
      deviceId: input.challenge.deviceId,
      appVersion: input.challenge.appVersion,
      architecture: input.challenge.architecture,
      releaseDigestSha256: input.challenge.releaseDigestSha256,
      policyId: input.challenge.policyId,
      attestationKind: input.challenge.attestationKind,
      trustClass: "linux_lower_trust",
      verifierReceiptHash: sha256Hex(`mock|${input.challenge.challengeId}|${mac}`),
      attestedAtMillis: input.nowMillis,
      expiresAtMillis: input.challenge.expiresAtMillis,
    };
  }
}

function runtimePolicy(environment: NodeJS.ProcessEnv = process.env): LinuxAppCheckRuntimePolicy {
  const config = getConfig();
  const rawURL = environment.LINUX_APP_CHECK_VERIFIER_URL?.trim();
  let verifierURL: URL | undefined;
  if (rawURL) {
    try {
      const parsed = new URL(rawURL);
      if (
        parsed.protocol === "https:" &&
        parsed.username === "" &&
        parsed.password === "" &&
        parsed.search === "" &&
        parsed.hash === ""
      ) {
        verifierURL = parsed;
      }
    } catch {
      verifierURL = undefined;
    }
  }
  return {
    mintEnabled: environment.LINUX_APP_CHECK_MINT_ENABLED?.trim().toLowerCase() === "true",
    appId: config.linuxAppCheckAppID,
    policyId: environment.LINUX_APP_CHECK_POLICY_ID?.trim() || LINUX_ATTESTATION_POLICY_DEFAULT,
    verifierURL,
    verifierOIDCAudience: environment.LINUX_APP_CHECK_VERIFIER_OIDC_AUDIENCE?.trim(),
    verifierPublicKeyBase64: environment.LINUX_APP_CHECK_VERIFIER_PUBLIC_KEY_BASE64?.trim(),
    verifierKeyID: environment.LINUX_APP_CHECK_VERIFIER_KEY_ID?.trim(),
    verifierIssuer: environment.LINUX_APP_CHECK_VERIFIER_ISSUER?.trim(),
    verifierAudience: environment.LINUX_APP_CHECK_VERIFIER_AUDIENCE?.trim(),
  };
}

function assertProductionPolicyConfigured(policy: LinuxAppCheckRuntimePolicy): void {
  if (!policy.mintEnabled) {
    throw new HttpsError("failed-precondition", "Linux production App Check minting is disabled.");
  }
  if (policy.appId === PLACEHOLDER_LINUX_APP_CHECK_APP_ID || !REAL_FIREBASE_WEB_APP_ID.test(policy.appId)) {
    throw new HttpsError("failed-precondition", "A dedicated Firebase Web app id is required for Linux App Check.");
  }
  if (
    !policy.verifierURL ||
    !policy.verifierOIDCAudience ||
    !policy.verifierPublicKeyBase64 ||
    !policy.verifierKeyID ||
    !policy.verifierIssuer ||
    !policy.verifierAudience
  ) {
    throw new HttpsError("failed-precondition", "Linux production App Check verifier configuration is incomplete.");
  }
  if (policy.verifierOIDCAudience !== policy.verifierURL.origin) {
    throw new HttpsError(
      "failed-precondition",
      "Linux verifier OIDC audience must exactly match the configured verifier HTTPS origin.",
    );
  }
}

function assertProductionAppIDAllowlisted(policy: LinuxAppCheckRuntimePolicy, allowedAppIDs: string[]): void {
  assertProductionPolicyConfigured(policy);
  if (!isAppCheckAppIdAllowed(policy.appId, { allowedAppCheckAppIDs: allowedAppIDs })) {
    throw new HttpsError("failed-precondition", "The Linux Firebase app id is not operator-allowlisted.");
  }
}

function buildLinuxAttestationVerifiers(options: {
  allowMock: boolean;
  policy: LinuxAppCheckRuntimePolicy;
  mockSharedSecret?: string;
  identityTokenProvider?: LinuxVerifierIdentityTokenProvider;
}): Map<string, LinuxAttestationVerifier> {
  const result = new Map<string, LinuxAttestationVerifier>();
  if (options.allowMock) {
    result.set(MOCK_ATTESTATION_KIND, new MockLinuxAttestationVerifier(options.mockSharedSecret));
  }
  if (options.policy.mintEnabled) {
    assertProductionPolicyConfigured(options.policy);
    result.set(
      LINUX_ATTESTATION_KIND,
      new RemoteSignedLinuxAttestationVerifier({
        endpoint: options.policy.verifierURL!,
        oidcAudience: options.policy.verifierOIDCAudience!,
        publicKeyBase64: options.policy.verifierPublicKeyBase64!,
        keyId: options.policy.verifierKeyID!,
        issuer: options.policy.verifierIssuer!,
        audience: options.policy.verifierAudience!,
        identityTokenProvider: options.identityTokenProvider,
      }),
    );
  }
  return result;
}

interface IssueLinuxChallengeParams {
  binding: LinuxAttestationBinding;
  store: LinuxAttestationChallengeStore;
  nowMillis: number;
}

async function issueLinuxAppCheckChallengeCore(params: IssueLinuxChallengeParams): Promise<LinuxAttestationChallenge> {
  return params.store.create(params.binding, params.nowMillis);
}

interface MintLinuxAppCheckParams {
  uid: string;
  rawEvidence: unknown;
  store: LinuxAttestationChallengeStore;
  verifiers: Map<string, LinuxAttestationVerifier>;
  enrollmentTrustStore?: LinuxAttestationEnrollmentTrustStore;
  allowedAppIDs: string[];
  createToken: AppCheckTokenMinter;
  recordSession: (
    decision: LinuxAttestationDecision,
    sessionID: string,
    tokenHash: string,
    expiresAtMillis: number,
  ) => Promise<void>;
  nowMillis: number;
  currentTimeMillis?: () => number;
}

interface MintLinuxAppCheckResult {
  appCheckToken: string;
  issuedAtMillis: number;
  expireTimeMillis: number;
  appId: string;
  trustClass: "linux_lower_trust";
}

async function mintLinuxAppCheckTokenCore(params: MintLinuxAppCheckParams): Promise<MintLinuxAppCheckResult> {
  const currentTimeMillis = params.currentTimeMillis ?? (() => params.nowMillis);
  const evidence = parseLinuxAttestationEvidence(params.rawEvidence);
  const stored = await params.store.load(params.uid, evidence.challengeId);
  if (!stored || stored.uid !== params.uid) {
    throw new HttpsError(
      "permission-denied",
      "Linux attestation challenge is missing or does not belong to this account.",
    );
  }
  const challenge = {
    ...assertChallengeBinding(stored, evidence.challenge, params.nowMillis),
    challengeId: evidence.challengeId,
  };
  if (challenge.attestationKind !== evidence.kind) {
    throw new HttpsError("permission-denied", "Linux attestation kind does not match the challenge.");
  }
  const verifier = params.verifiers.get(evidence.kind);
  if (!verifier) {
    throw new HttpsError("permission-denied", "No configured Linux attestation verifier accepted this evidence kind.");
  }
  const decision = await verifier.verify({ challenge, evidence: evidence.evidence, nowMillis: params.nowMillis });
  const verifiedAtMillis = currentTimeMillis();
  if (
    decision.uid !== params.uid ||
    decision.appId !== challenge.appId ||
    decision.deviceId !== challenge.deviceId ||
    decision.appVersion !== challenge.appVersion ||
    decision.architecture !== challenge.architecture ||
    decision.releaseDigestSha256 !== challenge.releaseDigestSha256 ||
    decision.policyId !== challenge.policyId ||
    decision.attestationKind !== challenge.attestationKind ||
    decision.trustClass !== "linux_lower_trust" ||
    challenge.expiresAtMillis < verifiedAtMillis ||
    decision.expiresAtMillis < verifiedAtMillis ||
    decision.attestedAtMillis > verifiedAtMillis + 60_000
  ) {
    throw new HttpsError("permission-denied", "Linux attestation verifier returned a mismatched identity binding.");
  }
  if (!isAppCheckAppIdAllowed(decision.appId, { allowedAppCheckAppIDs: params.allowedAppIDs })) {
    throw new HttpsError("permission-denied", "Linux App Check app id is not allowlisted.");
  }
  if (decision.attestationKind === LINUX_ATTESTATION_KIND) {
    if (!params.enrollmentTrustStore) {
      throw new HttpsError("failed-precondition", "Linux enrollment trust store is not configured.");
    }
    await params.enrollmentTrustStore.requireActive(params.uid, decision.deviceId);
  }

  await params.store.consume(params.uid, evidence.challengeId, sha256Hex(evidence.challenge), verifiedAtMillis);
  const issuedAtMillis = currentTimeMillis();
  const minted = await params.createToken(decision.appId, { ttlMillis: LINUX_APP_CHECK_TOKEN_TTL_MS });
  if (!minted.token || minted.ttlMillis !== LINUX_APP_CHECK_TOKEN_TTL_MS) {
    throw new HttpsError("internal", "Firebase App Check returned an unexpected token lifetime.");
  }
  const expireTimeMillis = issuedAtMillis + LINUX_APP_CHECK_TOKEN_TTL_MS;
  const sessionID = sha256Hex(`${params.uid}|${evidence.challengeId}|${decision.verifierReceiptHash}`);
  await params.recordSession(decision, sessionID, sha256Hex(minted.token), expireTimeMillis);
  return {
    appCheckToken: minted.token,
    issuedAtMillis,
    expireTimeMillis,
    appId: decision.appId,
    trustClass: "linux_lower_trust",
  };
}

const defaultCreateToken: AppCheckTokenMinter = (appId, options) => getAppCheck().createToken(appId, options);
const challengeStore = new FirestoreLinuxAttestationChallengeStore(db);
const enrollmentTrustStore = new FirestoreLinuxAttestationEnrollmentTrustStore(db);
const ticketAuthority = new FirestoreLinuxAttestationTicketAuthority(db);

async function recordLinuxAttestationSession(
  decision: LinuxAttestationDecision,
  sessionID: string,
  tokenHash: string,
  expiresAtMillis: number,
): Promise<void> {
  await db.doc(`users/${decision.uid}/linux_app_check_sessions/${sessionID}`).create({
    protocolVersion: 1,
    appId: decision.appId,
    deviceId: decision.deviceId,
    appVersion: decision.appVersion,
    architecture: decision.architecture,
    releaseDigestSha256: decision.releaseDigestSha256,
    policyId: decision.policyId,
    attestationKind: decision.attestationKind,
    trustClass: decision.trustClass,
    verifierReceiptHash: decision.verifierReceiptHash,
    tokenHashSha256: tokenHash,
    attestedAtMillis: decision.attestedAtMillis,
    expiresAtMillis,
    createdAt: Timestamp.fromMillis(decision.attestedAtMillis),
    expireAt: Timestamp.fromMillis(expiresAtMillis),
  });
}

export const issueLinuxAppCheckChallenge = onCall(
  { region: FUNCTIONS_REGION, enforceAppCheck: false, maxInstances: 20 },
  wrapCallableHandler("issueLinuxAppCheckChallenge", async (request: CallableRequest<Record<string, unknown>>) => {
    assertAuth(request);
    const uid = request.auth!.uid;
    await checkPublicHttpEndpointRateLimit("issueLinuxAppCheckChallenge", uid);
    const config = getConfig();
    const policy = runtimePolicy();
    const requestedKind = typeof request.data?.attestationKind === "string" ? request.data.attestationKind : "";
    const mockRequested = requestedKind === MOCK_ATTESTATION_KIND && config.allowMockAppCheckAttestation;
    if (!mockRequested) assertProductionAppIDAllowlisted(policy, config.allowedAppCheckAppIDs);
    const binding = parseLinuxAttestationBinding(request.data, {
      uid,
      appId: policy.appId,
      policyId: policy.policyId,
    });
    if (binding.attestationKind !== (mockRequested ? MOCK_ATTESTATION_KIND : LINUX_ATTESTATION_KIND)) {
      throw new HttpsError("permission-denied", "Linux attestation kind is not enabled by the server policy.");
    }
    const result = await issueLinuxAppCheckChallengeCore({ binding, store: challengeStore, nowMillis: Date.now() });
    return {
      challengeId: result.challengeId,
      challenge: result.challenge,
      expiresAtMillis: result.expiresAtMillis,
      appId: result.appId,
      policyId: result.policyId,
      protocolVersion: result.protocolVersion,
    };
  }),
);

export const mintLinuxAppCheckToken = onCall(
  { region: FUNCTIONS_REGION, enforceAppCheck: false, maxInstances: 20 },
  wrapCallableHandler("mintLinuxAppCheckToken", async (request: CallableRequest<{ attestation?: unknown }>) => {
    assertAuth(request);
    const uid = request.auth!.uid;
    await checkPublicHttpEndpointRateLimit("mintLinuxAppCheckToken", uid);
    parseCallableInput("mintLinuxAppCheckToken", {}, request.data);
    if (request.data?.attestation === undefined) {
      throw new HttpsError("invalid-argument", "mintLinuxAppCheckToken: attestation is required.");
    }
    const config = getConfig();
    const policy = runtimePolicy();
    if (!config.allowMockAppCheckAttestation) {
      assertProductionAppIDAllowlisted(policy, config.allowedAppCheckAppIDs);
    }
    const result = await mintLinuxAppCheckTokenCore({
      uid,
      rawEvidence: request.data.attestation,
      store: challengeStore,
      verifiers: buildLinuxAttestationVerifiers({
        allowMock: config.allowMockAppCheckAttestation,
        policy,
      }),
      enrollmentTrustStore,
      allowedAppIDs: config.allowedAppCheckAppIDs,
      createToken: defaultCreateToken,
      recordSession: recordLinuxAttestationSession,
      nowMillis: Date.now(),
      currentTimeMillis: Date.now,
    });
    logInfo({
      event: "callable_info",
      message: "linux_app_check_token_minted",
      app_id: result.appId,
      ttl_millis: LINUX_APP_CHECK_TOKEN_TTL_MS,
      trust_class: result.trustClass,
    });
    return { ok: true, ...result };
  }),
);

export const issueLinuxAttestationUploadTicket = onCall(
  { region: FUNCTIONS_REGION, enforceAppCheck: false, maxInstances: 20 },
  wrapCallableHandler(
    "issueLinuxAttestationUploadTicket",
    async (request: CallableRequest<Record<string, unknown>>) => {
      assertAuth(request);
      const uid = request.auth!.uid;
      await checkPublicHttpEndpointRateLimit("issueLinuxAttestationUploadTicket", uid);
      parseCallableInput("issueLinuxAttestationUploadTicket", {}, request.data);
      const config = getConfig();
      const policy = runtimePolicy();
      assertProductionAppIDAllowlisted(policy, config.allowedAppCheckAppIDs);
      const result = await ticketAuthority.issueUpload(parseLinuxUploadTicketRequest(request.data, uid));
      logInfo({
        event: "callable_info",
        message: "linux_attestation_upload_ticket_issued",
        purpose: "evidence_upload",
      });
      return { ok: true, ...result };
    },
  ),
);

export const issueLinuxAttestationEnrollmentTicket = onCall(
  { region: FUNCTIONS_REGION, enforceAppCheck: false, maxInstances: 10 },
  wrapCallableHandler(
    "issueLinuxAttestationEnrollmentTicket",
    async (request: CallableRequest<Record<string, unknown>>) => {
      assertAuth(request);
      const uid = request.auth!.uid;
      await checkPublicHttpEndpointRateLimit("issueLinuxAttestationEnrollmentTicket", uid);
      parseCallableInput("issueLinuxAttestationEnrollmentTicket", {}, request.data);
      const config = getConfig();
      const policy = runtimePolicy();
      assertProductionAppIDAllowlisted(policy, config.allowedAppCheckAppIDs);
      const result = await ticketAuthority.issueEnrollment(parseLinuxEnrollmentTicketRequest(request.data, uid));
      logInfo({
        event: "callable_info",
        message: "linux_attestation_enrollment_ticket_issued",
        purpose: "enrollment_begin",
      });
      return { ok: true, ...result };
    },
  ),
);

export const __testing__ = {
  MockLinuxAttestationVerifier,
  buildLinuxAttestationVerifiers,
  issueLinuxAppCheckChallengeCore,
  mintLinuxAppCheckTokenCore,
  mockMac,
  runtimePolicy,
  assertProductionPolicyConfigured,
  assertProductionAppIDAllowlisted,
  MOCK_ATTESTATION_KIND,
};
