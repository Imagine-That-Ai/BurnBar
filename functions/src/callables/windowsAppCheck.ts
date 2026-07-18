/**
 * @fileoverview mintWindowsAppCheckToken — the greenfield server half of the
 * Windows-port custom App Check pipeline.
 *
 * A Windows client cannot use Apple App Attest or Android Play Integrity, so it
 * proves possession of a hardware-backed Windows installation key via TPM key
 * attestation and exchanges that lower-trust device signal for a Firebase App
 * Check token minted here with `admin.appCheck().createToken(appId, {ttlMillis})`.
 * This is the FIRST `createToken` caller in the codebase.
 *
 * Trust model — attestation-gated, NOT endpoint-disabled:
 *   • The non-production MOCK verifier uses a shared
 *     fixture secret. It accepts a well-formed, freshly-signed, single-use mock
 *     claim and rejects invalid / forged / replayed ones.
 *   • The mock verifier is registered ONLY under non-production config
 *     (`allowMockAppCheckAttestation`, forced false in prod by config.ts). Under
 *     production config the verifier registry has NO verifier for a mock claim,
 *     so a mock/unverified claim finds no accepting verifier and cannot mint.
 *   • Production registers the TPM verifier only when the HTTPS verifier service,
 *     Secret Manager credential, and non-placeholder app id are configured.
 *     Server challenges are consumed transactionally before minting.
 *
 * There is deliberately no `if (prod) disable endpoint` branch: the fence is the
 * absence of an accepting verifier, not a disabled route.
 */

import { createHash, randomBytes, timingSafeEqual } from "node:crypto";

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import { getAppCheck } from "firebase-admin/app-check";
import type { AppCheckToken, AppCheckTokenOptions } from "firebase-admin/app-check";
import { FieldValue, getFirestore, Timestamp } from "firebase-admin/firestore";

import { getConfig, isAppCheckAppIdAllowed, PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID } from "../config.js";
import { isRecord } from "../guards.js";
import { assertAuth } from "../auth.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { checkPublicHttpEndpointRateLimit } from "./publicRateLimit.js";
import { parseCallableInput, requiredString } from "../validation/callableSchema.js";
import { providerFetch } from "../providers/httpClient.js";

/** Discriminator for the Phase-0 mock attestation claim. */
const MOCK_ATTESTATION_KIND = "mock" as const;

/**
 * Domain-separation prefix for the mock attestation MAC. Distinct from any real
 * attestation domain so a mock signature can never be mistaken for a real one.
 */
const MOCK_ATTESTATION_DOMAIN = "openburnbar.appcheck.windows.mock.v1";

/**
 * Shared secret for the MOCK fixture ONLY. This is NOT a production secret and is
 * never used by the real verifier: it exists so unit tests (and local dev) can
 * forge a valid mock claim. It is inert in production because the mock verifier is
 * never registered there (see {@link buildWindowsAttestationVerifiers}).
 */
const MOCK_ATTESTATION_SHARED_SECRET = "openburnbar-windows-appcheck-mock-fixture-secret";

/** A mock claim older than this (relative to now) is treated as stale/replayed. */
const MOCK_ATTESTATION_MAX_AGE_MS = 5 * 60 * 1000; // 5 minutes
/** Small forward-skew tolerance for client/server clock drift. */
const MOCK_ATTESTATION_CLOCK_SKEW_MS = 60 * 1000; // 1 minute

/** Default minted-token TTL (Firebase requires 30 minutes .. 7 days). */
const DEFAULT_MINT_TTL_MS = 30 * 60 * 1000; // 30 minutes
const MIN_MINT_TTL_MS = 30 * 60 * 1000;
const MAX_MINT_TTL_MS = 7 * 24 * 60 * 60 * 1000;

const MIN_NONCE_LENGTH = 16;
const MAX_NONCE_LENGTH = 256;
const TPM_ATTESTATION_KIND = "tpm" as const;
const TPM_ATTESTATION_MAX_AGE_MS = 5 * 60 * 1000;
const CHALLENGE_TTL_MS = 2 * 60 * 1000;
const WINDOWS_CHALLENGE_COLLECTION = "windows_app_check_challenges";
const MAX_TPM_UID_LENGTH = 256;
const MAX_TPM_APP_ID_LENGTH = 256;
const MAX_TPM_CHALLENGE_ID_LENGTH = 256;
const MAX_TPM_SUBJECT_PUBLIC_KEY_BASE64_LENGTH = 128;
const MAX_TPM_PLATFORM_CLAIM_BYTES = 64 * 1024;
const MAX_TPM_PLATFORM_CLAIM_BASE64_LENGTH = 4 * Math.ceil(MAX_TPM_PLATFORM_CLAIM_BYTES / 3);
const WINDOWS_TPM_VERIFIER_TOKEN = defineSecret("WINDOWS_TPM_VERIFIER_TOKEN");

/** A Windows platform attestation claim presented to the mint endpoint. */
export interface WindowsAttestationClaim {
  /** Verifier discriminator, e.g. {@link MOCK_ATTESTATION_KIND}. */
  kind: string;
  /** App Check app id the attestation is bound to (must be allowlisted). */
  appId: string;
  /** Single-use, replay-defeating nonce. */
  nonce: string;
  /** Client-asserted issue time in epoch millis (freshness-checked). */
  issuedAtMs: number;
  /** Mock MAC (hex) or raw CNG platform claim (base64), selected by kind. */
  mac: string;
  /** Server-issued one-time challenge identifier. Required for TPM claims. */
  challengeId?: string;
  /** Base64 CNG public-key blob for the TPM-backed subject key. */
  subjectPublicKey?: string;
}

type VerifyResult =
  | { ok: true; appId: string; requiresChallenge?: boolean }
  | { ok: false; reason: AttestationRejectReason };

type AttestationRejectReason =
  | "malformed"
  | "app_id_not_expected"
  | "stale"
  | "forged"
  | "replayed"
  | "verifier_unavailable";

/**
 * A verifier proves a platform attestation claim and returns the bound app id.
 * The registry maps a claim `kind` to the verifier that can prove it. In Phase 0
 * implementations cover the non-production mock and production TPM paths.
 */
export interface WindowsAttestationVerifier {
  readonly kind: string;
  verify(claim: WindowsAttestationClaim, nowMillis: number, uid?: string): VerifyResult | Promise<VerifyResult>;
}

/** Compute the MOCK attestation MAC (hex) for a claim. Exposed for tests/clients. */
function signMockAttestation(input: { appId: string; nonce: string; issuedAtMs: number; secret?: string }): string {
  const secret = input.secret ?? MOCK_ATTESTATION_SHARED_SECRET;
  const payload = `${MOCK_ATTESTATION_DOMAIN}|${input.appId}|${input.nonce}|${input.issuedAtMs}|${secret}`;
  return createHash("sha256").update(payload).digest("hex");
}

function macsEqual(a: string, b: string): boolean {
  // Constant-time compare; timingSafeEqual throws on unequal length, so guard first.
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  return timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

/**
 * MOCK Phase-0 verifier: accepts a well-formed, freshly-signed, single-use claim
 * bound to the expected app id; rejects malformed / wrong-app / stale / forged /
 * replayed claims. Replay defense is an in-memory single-use nonce set (a durable
 * store is AC-013's concern once the real verifier ships).
 */
class MockWindowsAttestationVerifier implements WindowsAttestationVerifier {
  readonly kind = MOCK_ATTESTATION_KIND;

  constructor(
    private readonly expectedAppId: string,
    private readonly sharedSecret: string = MOCK_ATTESTATION_SHARED_SECRET,
    private readonly consumedNonces: Set<string> = new Set<string>(),
  ) {}

  verify(claim: WindowsAttestationClaim, nowMillis: number): VerifyResult {
    if (
      typeof claim.appId !== "string" ||
      claim.appId.length === 0 ||
      typeof claim.nonce !== "string" ||
      claim.nonce.length < MIN_NONCE_LENGTH ||
      claim.nonce.length > MAX_NONCE_LENGTH ||
      typeof claim.issuedAtMs !== "number" ||
      !Number.isFinite(claim.issuedAtMs) ||
      typeof claim.mac !== "string"
    ) {
      return { ok: false, reason: "malformed" };
    }
    if (claim.appId !== this.expectedAppId) {
      return { ok: false, reason: "app_id_not_expected" };
    }
    // Freshness: reject a claim signed too far in the past (a captured/replayed
    // old attestation) or implausibly in the future.
    const age = nowMillis - claim.issuedAtMs;
    if (age > MOCK_ATTESTATION_MAX_AGE_MS || age < -MOCK_ATTESTATION_CLOCK_SKEW_MS) {
      return { ok: false, reason: "stale" };
    }
    const expectedMac = signMockAttestation({
      appId: claim.appId,
      nonce: claim.nonce,
      issuedAtMs: claim.issuedAtMs,
      secret: this.sharedSecret,
    });
    if (!macsEqual(expectedMac, claim.mac)) {
      return { ok: false, reason: "forged" };
    }
    // Single-use: a nonce may verify at most once, even within its freshness
    // window, defeating replay of a captured valid claim.
    if (this.consumedNonces.has(claim.nonce)) {
      return { ok: false, reason: "replayed" };
    }
    this.consumedNonces.add(claim.nonce);
    return { ok: true, appId: claim.appId };
  }
}

export type WindowsTpmVerifierFetch = (
  provider: string,
  operation: string,
  url: string | URL,
  init?: RequestInit,
) => Promise<Response>;

function isWellFormedTpmClaim(claim: WindowsAttestationClaim, uid: string | undefined): uid is string {
  return (
    typeof uid === "string" &&
    uid.length > 0 &&
    uid.length <= MAX_TPM_UID_LENGTH &&
    claim.appId.length > 0 &&
    claim.appId.length <= MAX_TPM_APP_ID_LENGTH &&
    typeof claim.challengeId === "string" &&
    claim.challengeId.length >= 16 &&
    claim.challengeId.length <= MAX_TPM_CHALLENGE_ID_LENGTH &&
    typeof claim.subjectPublicKey === "string" &&
    claim.subjectPublicKey.length >= 32 &&
    claim.subjectPublicKey.length <= MAX_TPM_SUBJECT_PUBLIC_KEY_BASE64_LENGTH &&
    typeof claim.mac === "string" &&
    claim.mac.length >= 32 &&
    claim.mac.length <= MAX_TPM_PLATFORM_CLAIM_BASE64_LENGTH &&
    typeof claim.nonce === "string" &&
    claim.nonce.length >= MIN_NONCE_LENGTH &&
    claim.nonce.length <= MAX_NONCE_LENGTH &&
    Number.isFinite(claim.issuedAtMs)
  );
}

/**
 * Production TPM verifier adapter. The opaque CNG platform claim is sent over an
 * authenticated HTTPS channel to a Windows-hosted service that calls
 * NCryptVerifyClaim. Cloud Functions deliberately does not attempt to parse or
 * approximate Microsoft's platform-claim format on Linux.
 */
class WindowsTpmAttestationVerifier implements WindowsAttestationVerifier {
  readonly kind = TPM_ATTESTATION_KIND;

  constructor(
    private readonly expectedAppId: string,
    private readonly verifierURL: string,
    private readonly verifierToken: string,
    private readonly fetcher: WindowsTpmVerifierFetch = providerFetch,
  ) {}

  async verify(claim: WindowsAttestationClaim, nowMillis: number, uid?: string): Promise<VerifyResult> {
    if (claim.appId !== this.expectedAppId) return { ok: false, reason: "app_id_not_expected" };
    if (!isWellFormedTpmClaim(claim, uid)) return { ok: false, reason: "malformed" };
    const age = nowMillis - claim.issuedAtMs;
    if (age > TPM_ATTESTATION_MAX_AGE_MS || age < -MOCK_ATTESTATION_CLOCK_SKEW_MS) {
      return { ok: false, reason: "stale" };
    }

    try {
      const response = await this.fetcher("windows-tpm-attestation", "verify-claim", this.verifierURL, {
        method: "POST",
        redirect: "error",
        headers: {
          authorization: `Bearer ${this.verifierToken}`,
          "content-type": "application/json",
          accept: "application/json",
        },
        body: JSON.stringify({
          version: 1,
          uid,
          appId: claim.appId,
          challengeId: claim.challengeId,
          nonce: claim.nonce,
          issuedAtMs: claim.issuedAtMs,
          platformClaim: claim.mac,
          subjectPublicKey: claim.subjectPublicKey,
        }),
      });
      if (response.status === 400) return { ok: false, reason: "malformed" };
      if (response.status === 401 || response.status === 403) return { ok: false, reason: "forged" };
      if (!response.ok) return { ok: false, reason: "verifier_unavailable" };
      const payload: unknown = await response.json();
      if (!isRecord(payload) || payload.valid !== true) return { ok: false, reason: "forged" };
      if (
        payload.uid !== uid ||
        payload.appId !== claim.appId ||
        payload.challengeId !== claim.challengeId ||
        payload.nonce !== claim.nonce
      ) {
        return { ok: false, reason: "forged" };
      }
      return { ok: true, appId: claim.appId, requiresChallenge: true };
    } catch {
      return { ok: false, reason: "verifier_unavailable" };
    }
  }
}

/**
 * Build the attestation verifier registry for the current config.
 *
 * The mock fence and TPM registration are independent. Production never registers
 * mock; TPM registers only with complete, non-placeholder production config.
 */
function buildWindowsAttestationVerifiers(opts: {
  allowMock: boolean;
  expectedAppId: string;
  sharedSecret?: string;
  replayStore?: Set<string>;
  tpmVerifierURL?: string;
  tpmVerifierToken?: string;
  tpmVerifierFetch?: WindowsTpmVerifierFetch;
}): Map<string, WindowsAttestationVerifier> {
  const verifiers = new Map<string, WindowsAttestationVerifier>();
  if (opts.allowMock) {
    verifiers.set(
      MOCK_ATTESTATION_KIND,
      new MockWindowsAttestationVerifier(opts.expectedAppId, opts.sharedSecret, opts.replayStore),
    );
  }
  if (
    isValidTpmVerifierConfig(opts.tpmVerifierURL, opts.tpmVerifierToken) &&
    opts.expectedAppId !== PLACEHOLDER_WINDOWS_APP_CHECK_APP_ID &&
    opts.tpmVerifierURL &&
    opts.tpmVerifierToken
  ) {
    verifiers.set(
      TPM_ATTESTATION_KIND,
      new WindowsTpmAttestationVerifier(
        opts.expectedAppId,
        opts.tpmVerifierURL,
        opts.tpmVerifierToken,
        opts.tpmVerifierFetch,
      ),
    );
  }
  return verifiers;
}

function isValidTpmVerifierConfig(url: string | undefined, token: string | undefined): url is string {
  if (!url || !token || token.length < 32) return false;
  try {
    const parsed = new URL(url);
    return parsed.protocol === "https:" && !parsed.username && !parsed.password && !parsed.hash;
  } catch {
    return false;
  }
}

function rejectReasonToError(reason: AttestationRejectReason): HttpsError {
  switch (reason) {
    case "malformed":
      return new HttpsError("invalid-argument", "The attestation claim is malformed.");
    case "app_id_not_expected":
      return new HttpsError("permission-denied", "The attestation is bound to an unexpected app id.");
    case "stale":
      return new HttpsError("unauthenticated", "The attestation is stale; request a fresh one.");
    case "forged":
      return new HttpsError("unauthenticated", "The attestation signature did not verify.");
    case "replayed":
      return new HttpsError("unauthenticated", "The attestation nonce was already used.");
    case "verifier_unavailable":
      return new HttpsError("unavailable", "The TPM attestation verifier is unavailable.");
  }
}

function parseAttestationClaim(raw: unknown): WindowsAttestationClaim {
  if (!isRecord(raw)) {
    throw new HttpsError("invalid-argument", "An attestation claim is required.");
  }
  return {
    kind: typeof raw.kind === "string" ? raw.kind : "",
    appId: typeof raw.appId === "string" ? raw.appId : "",
    nonce: typeof raw.nonce === "string" ? raw.nonce : "",
    issuedAtMs: typeof raw.issuedAtMs === "number" ? raw.issuedAtMs : Number.NaN,
    mac: typeof raw.mac === "string" ? raw.mac : "",
    challengeId: typeof raw.challengeId === "string" ? raw.challengeId : undefined,
    subjectPublicKey: typeof raw.subjectPublicKey === "string" ? raw.subjectPublicKey : undefined,
  };
}

function clampTtl(raw: unknown): number {
  if (typeof raw !== "number" || !Number.isFinite(raw)) return DEFAULT_MINT_TTL_MS;
  return Math.min(MAX_MINT_TTL_MS, Math.max(MIN_MINT_TTL_MS, Math.floor(raw)));
}

/** Injectable createToken so the mint path is unit-testable without live Firebase. */
export type AppCheckTokenMinter = (appId: string, options?: AppCheckTokenOptions) => Promise<AppCheckToken>;

export interface WindowsAttestationChallenge {
  challengeId: string;
  nonce: string;
  expiresAtMs: number;
}

export interface WindowsAttestationChallengeStore {
  issue(uid: string, appId: string, nowMillis: number): Promise<WindowsAttestationChallenge>;
  consume(
    uid: string,
    appId: string,
    challengeId: string,
    nonce: string,
    nowMillis: number,
  ): Promise<"ok" | "missing" | "mismatch" | "expired" | "replayed">;
}

class FirestoreWindowsAttestationChallengeStore implements WindowsAttestationChallengeStore {
  async issue(uid: string, appId: string, nowMillis: number): Promise<WindowsAttestationChallenge> {
    const challengeId = randomBytes(24).toString("base64url");
    const nonce = randomBytes(32).toString("base64url");
    const expiresAtMs = nowMillis + CHALLENGE_TTL_MS;
    await getFirestore()
      .collection(WINDOWS_CHALLENGE_COLLECTION)
      .doc(challengeId)
      .create({
        uid,
        appId,
        nonceHash: createHash("sha256").update(nonce).digest("hex"),
        issuedAtMs: nowMillis,
        expiresAtMs,
        expiresAt: Timestamp.fromMillis(expiresAtMs),
        createdAt: FieldValue.serverTimestamp(),
      });
    return { challengeId, nonce, expiresAtMs };
  }

  async consume(
    uid: string,
    appId: string,
    challengeId: string,
    nonce: string,
    nowMillis: number,
  ): Promise<"ok" | "missing" | "mismatch" | "expired" | "replayed"> {
    const reference = getFirestore().collection(WINDOWS_CHALLENGE_COLLECTION).doc(challengeId);
    return getFirestore().runTransaction(async (transaction) => {
      const snapshot = await transaction.get(reference);
      if (!snapshot.exists) return "missing";
      const data = snapshot.data();
      if (data?.consumedAt != null) return "replayed";
      if (data?.uid !== uid || data?.appId !== appId) return "mismatch";
      if (typeof data?.expiresAtMs !== "number" || data.expiresAtMs <= nowMillis) return "expired";
      const nonceHash = createHash("sha256").update(nonce).digest("hex");
      if (data?.nonceHash !== nonceHash) return "mismatch";
      transaction.update(reference, { consumedAt: FieldValue.serverTimestamp(), consumedAtMs: nowMillis });
      return "ok";
    });
  }
}

async function issueWindowsAppCheckChallengeCore(params: {
  uid: string;
  appId: string;
  expectedAppId: string;
  allowedAppIDs: string[];
  store: WindowsAttestationChallengeStore;
  nowMillis: number;
}): Promise<WindowsAttestationChallenge> {
  if (
    params.appId !== params.expectedAppId ||
    !isAppCheckAppIdAllowed(params.appId, {
      allowedAppCheckAppIDs: params.allowedAppIDs,
    })
  ) {
    throw new HttpsError("permission-denied", "Windows App Check app id is not allowed.");
  }
  return params.store.issue(params.uid, params.appId, params.nowMillis);
}

interface MintWindowsAppCheckParams {
  claim: unknown;
  verifiers: Map<string, WindowsAttestationVerifier>;
  allowedAppIDs: string[];
  createToken: AppCheckTokenMinter;
  nowMillis: number;
  ttlMillis?: number;
  uid?: string;
  challengeStore?: WindowsAttestationChallengeStore;
}

interface MintWindowsAppCheckResult {
  appCheckToken: string;
  ttlMillis: number;
  appId: string;
}

/**
 * Pure mint core: resolve a verifier for the claim, verify it, confirm the bound
 * app id is allowlisted, then mint. Fail-closed at every step.
 */
async function mintWindowsAppCheckTokenCore(params: MintWindowsAppCheckParams): Promise<MintWindowsAppCheckResult> {
  const claim = parseAttestationClaim(params.claim);

  // No verifier for this claim kind means nothing can prove it and nothing mints.
  const verifier = params.verifiers.get(claim.kind);
  if (!verifier) {
    throw new HttpsError("permission-denied", "No registered App Check attestation verifier accepted this claim.");
  }

  const result = await verifier.verify(claim, params.nowMillis, params.uid);
  if (!result.ok) {
    throw rejectReasonToError(result.reason);
  }

  if (!isAppCheckAppIdAllowed(result.appId, { allowedAppCheckAppIDs: params.allowedAppIDs })) {
    throw new HttpsError("permission-denied", "App Check app id is not allowlisted.");
  }

  if (result.requiresChallenge) {
    if (!params.uid || !params.challengeStore || !claim.challengeId) {
      throw new HttpsError("unauthenticated", "A server-issued attestation challenge is required.");
    }
    const consumeResult = await params.challengeStore.consume(
      params.uid,
      result.appId,
      claim.challengeId,
      claim.nonce,
      params.nowMillis,
    );
    if (consumeResult !== "ok") {
      throw rejectReasonToError(
        consumeResult === "replayed" ? "replayed" : consumeResult === "expired" ? "stale" : "forged",
      );
    }
  }

  const ttlMillis = clampTtl(params.ttlMillis);
  const token = await params.createToken(result.appId, { ttlMillis });
  return {
    appCheckToken: token.token,
    ttlMillis: token.ttlMillis,
    appId: result.appId,
  };
}

/** Test-only surface: pure verifier/mint internals with no Firestore or live admin. */
export const __testing__ = {
  MockWindowsAttestationVerifier,
  WindowsTpmAttestationVerifier,
  buildWindowsAttestationVerifiers,
  mintWindowsAppCheckTokenCore,
  issueWindowsAppCheckChallengeCore,
  signMockAttestation,
  MOCK_ATTESTATION_KIND,
  MOCK_ATTESTATION_SHARED_SECRET,
  MOCK_ATTESTATION_MAX_AGE_MS,
  DEFAULT_MINT_TTL_MS,
  TPM_ATTESTATION_KIND,
  CHALLENGE_TTL_MS,
  MAX_TPM_PLATFORM_CLAIM_BASE64_LENGTH,
  MAX_TPM_SUBJECT_PUBLIC_KEY_BASE64_LENGTH,
  MAX_TPM_CHALLENGE_ID_LENGTH,
  makeReplayStore: (): Set<string> => new Set<string>(),
};

/** Module-scoped replay store for the deployed callable's mock verifier. */
const moduleReplayStore = new Set<string>();
const moduleChallengeStore = new FirestoreWindowsAttestationChallengeStore();

/** Default minter — resolves the initialized admin app at request time. */
const defaultCreateToken: AppCheckTokenMinter = (appId, options) => getAppCheck().createToken(appId, options);

/** Issue a short-lived, authenticated nonce that a TPM claim must bind. */
export const issueWindowsAppCheckChallenge = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: false,
    maxInstances: 20,
  },
  wrapCallableHandler("issueWindowsAppCheckChallenge", async (request: CallableRequest<{ appId?: unknown }>) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Sign in before requesting an App Check challenge.");
    }
    assertAuth(request);
    await checkPublicHttpEndpointRateLimit("issueWindowsAppCheckChallenge", uid);
    const input = parseCallableInput(
      "issueWindowsAppCheckChallenge",
      { appId: requiredString({ maxLength: 256 }) },
      request.data,
    );
    if (typeof input.appId !== "string") {
      throw new HttpsError("invalid-argument", "appId is required.");
    }
    const config = getConfig();
    const challenge = await issueWindowsAppCheckChallengeCore({
      uid,
      appId: input.appId,
      expectedAppId: config.windowsAppCheckAppID,
      allowedAppIDs: config.allowedAppCheckAppIDs,
      store: moduleChallengeStore,
      nowMillis: Date.now(),
    });
    return { ok: true, ...challenge };
  }),
);

/**
 * Callable: exchange a platform attestation for a Firebase App Check token.
 *
 * `enforceAppCheck` is intentionally FALSE: this is the bootstrap that MINTS an
 * App Check token, so it cannot itself demand one (chicken-and-egg). The gate is
 * the attestation verifier, not App Check. In production no mock verifier is
 * registered, so only AC-013's real verifier will be able to mint.
 */
export const mintWindowsAppCheckToken = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: false,
    maxInstances: 20,
    secrets: [WINDOWS_TPM_VERIFIER_TOKEN],
  },
  wrapCallableHandler(
    "mintWindowsAppCheckToken",
    async (request: CallableRequest<{ attestation?: unknown; ttlMillis?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) {
        throw new HttpsError("unauthenticated", "Sign in before requesting a Windows App Check token.");
      }
      assertAuth(request);

      // App Check is not enforced on this bootstrap path, so bound mint abuse
      // per-uid before doing any attestation/mint work.
      await checkPublicHttpEndpointRateLimit("mintWindowsAppCheckToken", uid);
      const input = parseCallableInput(
        "mintWindowsAppCheckToken",
        {
          ttlMillis: {
            optional: true,
            parse: (v: unknown): number | undefined => (typeof v === "number" ? v : undefined),
          },
        },
        request.data,
      );
      if (request.data?.attestation === undefined) {
        throw new HttpsError("invalid-argument", "mintWindowsAppCheckToken: attestation is required.");
      }

      const config = getConfig();
      const result = await mintWindowsAppCheckTokenCore({
        claim: request.data?.attestation,
        verifiers: buildWindowsAttestationVerifiers({
          allowMock: config.allowMockAppCheckAttestation,
          expectedAppId: config.windowsAppCheckAppID,
          replayStore: moduleReplayStore,
          tpmVerifierURL: config.windowsTpmVerifierURL,
          tpmVerifierToken: WINDOWS_TPM_VERIFIER_TOKEN.value(),
        }),
        allowedAppIDs: config.allowedAppCheckAppIDs,
        createToken: defaultCreateToken,
        nowMillis: Date.now(),
        ttlMillis: typeof input.ttlMillis === "number" ? input.ttlMillis : undefined,
        uid,
        challengeStore: moduleChallengeStore,
      });

      logInfo({
        event: "callable_info",
        message: "windows_app_check_token_minted",
        app_id: result.appId,
        ttl_millis: result.ttlMillis,
      });

      return { ok: true, ...result };
    },
  ),
);
