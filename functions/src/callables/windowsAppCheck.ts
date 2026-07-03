/**
 * @fileoverview mintWindowsAppCheckToken — the greenfield server half of the
 * Windows-port App Check pipeline (Phase 0 / AC-011).
 *
 * A Windows client cannot use Apple App Attest or Android Play Integrity, so it
 * proves it is a genuine, unmodified app via a platform attestation (a TPM quote
 * in the real design — AC-013) and exchanges that attestation for a Firebase App
 * Check token minted here with `admin.appCheck().createToken(appId, {ttlMillis})`.
 * This is the FIRST `createToken` caller in the codebase.
 *
 * Trust model — attestation-gated, NOT endpoint-disabled:
 *   • MOCK verifier (dev/CI): accepts a well-formed, freshly-signed, single-use
 *     mock claim over a shared fixture secret; rejects invalid/forged/replayed.
 *     Registered ONLY under non-production config (`allowMockAppCheckAttestation`,
 *     forced false in prod by config.ts), so under prod config no verifier accepts
 *     a mock claim and it CANNOT mint.
 *   • REAL TPM verifier (AC-013): validates a TPM quote signed by an Attestation
 *     Identity Key whose SPKI fingerprint is a pinned trust anchor, embedding the
 *     freshness nonce. Registered in ALL configs (prod too), but the pinned-AIK
 *     trust set is EMPTY in prod today, so it FAILS CLOSED — it mints nothing
 *     until an operator provisions real TPM trust anchors + a real Windows app id.
 *
 * Both fences are the same shape: a claim only mints when SOME registered verifier
 * accepts it, and in prod none does yet. There is deliberately no `if (prod)
 * disable endpoint` branch — the fence is a failed attestation, not a dead route.
 */

import {
  createHash,
  timingSafeEqual,
  createVerify,
  createPublicKey,
  X509Certificate,
  type KeyObject,
} from "node:crypto";

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { getAppCheck } from "firebase-admin/app-check";
import type { AppCheckToken, AppCheckTokenOptions } from "firebase-admin/app-check";

import { getConfig, isAppCheckAppIdAllowed } from "../config.js";
import { isRecord } from "../guards.js";
import { assertAuth } from "../auth.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { checkPublicHttpEndpointRateLimit } from "./publicRateLimit.js";
import { parseCallableInput } from "../validation/callableSchema.js";

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
  /** Attestation signature/MAC over the claim (hex). */
  mac: string;
}

type VerifyResult = { ok: true; appId: string } | { ok: false; reason: AttestationRejectReason };

type AttestationRejectReason =
  | "malformed"
  | "app_id_not_expected"
  | "stale"
  | "forged"
  | "replayed"
  | "untrusted";

/**
 * A verifier proves a platform attestation claim and returns the bound app id.
 * The registry maps a claim `kind` to the verifier that can prove it. In Phase 0
 * the only implementation is {@link MockWindowsAttestationVerifier}; AC-013 adds a
 * real TPM verifier for the same interface.
 */
export interface WindowsAttestationVerifier {
  readonly kind: string;
  verify(claim: WindowsAttestationClaim, nowMillis: number): VerifyResult;
}

/** Compute the MOCK attestation MAC (hex) for a claim. Exposed for tests/clients. */
function signMockAttestation(input: {
  appId: string;
  nonce: string;
  issuedAtMs: number;
  secret?: string;
}): string {
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

/**
 * Load the Attestation Identity Key (AIK) public key from an attestation claim.
 * Accepts either a bare public-key PEM (SPKI/PKCS#1) or a full X.509 AIK/EK
 * certificate PEM; in the certificate case the embedded subject public key is
 * used. Throws on unparseable input (caller maps that to a rejection).
 */
function loadAikPublicKey(aikCertPem: string): KeyObject {
  if (aikCertPem.includes("BEGIN CERTIFICATE")) {
    return new X509Certificate(aikCertPem).publicKey;
  }
  return createPublicKey(aikCertPem);
}

/**
 * Canonical trust identity of an AIK: the lowercase hex SHA-256 over the key's
 * canonical SPKI DER encoding. Independent of the PEM wrapper (bare key vs.
 * certificate) so the same AIK always yields the same fingerprint. This is the
 * value an operator pins as a trusted-AIK anchor.
 */
function aikPublicKeyFingerprint(aikCertPem: string): string | null {
  try {
    const der = loadAikPublicKey(aikCertPem).export({ type: "spki", format: "der" });
    return createHash("sha256").update(der).digest("hex");
  } catch {
    return null;
  }
}

/** Normalize a pinned fingerprint to lowercase hex (drop `:`/whitespace separators). */
function normalizeFingerprint(fp: string): string {
  return fp.toLowerCase().replace(/[^0-9a-f]/g, "");
}

/**
 * REAL TPM attestation verifier (AC-013). Proves a Windows client is a genuine,
 * unmodified app by validating a TPM quote signed by an Attestation Identity Key
 * whose EK/AIK the operator has anchored as trusted:
 *
 *   1. shape / app-id / freshness (mirrors the mock verifier),
 *   2. parse the claim's `mac` (hex JSON) into `{ quote, signature, aikCertPem }`,
 *   3. TRUST ANCHOR — the presented AIK's SPKI-SHA256 fingerprint MUST be one of
 *      the pinned `trustedAikFingerprints`. With no anchors pinned the verifier
 *      FAILS CLOSED (every claim rejected `untrusted`), so a self-signed key can
 *      never mint. This is the AIK/EK trust check; without it the signature step
 *      below only proves "signed by whoever supplied the key", which is forgeable.
 *   4. verify the quote signature under the (now-trusted) AIK public key,
 *   5. bind freshness/anti-replay by requiring the claim nonce inside the quote.
 *
 * The trust set is empty under production config today (no real Windows app / TPM
 * roots provisioned yet), so this verifier mints NOTHING in prod — the same
 * fail-closed posture as the absent mock verifier — while the mint path stays
 * live for provisioning. It is registered in ALL configs; there is no prod-only
 * disable to remove.
 */
class WindowsTpmAttestationVerifier implements WindowsAttestationVerifier {
  readonly kind = "tpm";

  private readonly trustedAikFingerprints: Set<string>;

  constructor(
    private readonly expectedAppId: string,
    trustedAikFingerprints: readonly string[] = [],
  ) {
    this.trustedAikFingerprints = new Set(
      trustedAikFingerprints.map(normalizeFingerprint).filter((fp) => fp.length > 0),
    );
  }

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

    // Freshness: reject a quote signed too far in the past or implausibly ahead.
    const age = nowMillis - claim.issuedAtMs;
    if (age > MOCK_ATTESTATION_MAX_AGE_MS || age < -MOCK_ATTESTATION_CLOCK_SKEW_MS) {
      return { ok: false, reason: "stale" };
    }

    let quote: unknown;
    let signature: unknown;
    let aikCertPem: unknown;
    try {
      const payload: unknown = JSON.parse(Buffer.from(claim.mac, "hex").toString("utf8"));
      if (!isRecord(payload)) {
        return { ok: false, reason: "malformed" };
      }
      ({ quote, signature, aikCertPem } = payload);
    } catch {
      return { ok: false, reason: "malformed" };
    }
    if (
      typeof quote !== "string" || quote.length === 0 ||
      typeof signature !== "string" || signature.length === 0 ||
      typeof aikCertPem !== "string" || aikCertPem.length === 0
    ) {
      return { ok: false, reason: "malformed" };
    }

    // TRUST ANCHOR: the AIK must be pinned. Empty trust set ⇒ fail closed.
    const fingerprint = aikPublicKeyFingerprint(aikCertPem);
    if (fingerprint === null) {
      return { ok: false, reason: "malformed" };
    }
    if (!this.trustedAikFingerprints.has(fingerprint)) {
      return { ok: false, reason: "untrusted" };
    }

    try {
      // Verify the quote signature under the trusted AIK public key.
      const publicKey = loadAikPublicKey(aikCertPem);
      const verify = createVerify("sha256");
      verify.update(Buffer.from(quote, "hex"));
      if (!verify.verify(publicKey, Buffer.from(signature, "hex"))) {
        return { ok: false, reason: "forged" };
      }
    } catch {
      return { ok: false, reason: "forged" };
    }

    // Anti-replay: the freshly-issued client nonce must be embedded in the quote.
    const quoteBuffer = Buffer.from(quote, "hex");
    const nonceBuffer = Buffer.from(claim.nonce, "utf8");
    if (!quoteBuffer.includes(nonceBuffer)) {
      return { ok: false, reason: "replayed" };
    }

    return { ok: true, appId: claim.appId };
  }
}

/**
 * Build the attestation verifier registry for the current config.
 *
 * THE FENCE: under production config (`allowMock === false`) the registry is
 * EMPTY — no verifier is registered for a mock claim, so a mock/unverified claim
 * can never verify and never mint. The endpoint stays live. AC-013 registers its
 * real TPM verifier here (in prod too) with nothing to un-guard.
 */
function buildWindowsAttestationVerifiers(opts: {
  allowMock: boolean;
  expectedAppId: string;
  sharedSecret?: string;
  replayStore?: Set<string>;
  /**
   * Pinned trusted-AIK SPKI-SHA256 fingerprints for the real TPM verifier. Empty
   * (the prod default until AC-013 provisioning) ⇒ the TPM verifier fails closed.
   */
  trustedAikFingerprints?: readonly string[];
}): Map<string, WindowsAttestationVerifier> {
  const verifiers = new Map<string, WindowsAttestationVerifier>();
  if (opts.allowMock) {
    verifiers.set(
      MOCK_ATTESTATION_KIND,
      new MockWindowsAttestationVerifier(opts.expectedAppId, opts.sharedSecret, opts.replayStore),
    );
  }
  // AC-013: the real TPM verifier is registered in ALL configs (including prod).
  // With no trusted AIK fingerprints pinned it fails closed, so registering it in
  // prod cannot mint until an operator provisions real trust anchors.
  verifiers.set(
    "tpm",
    new WindowsTpmAttestationVerifier(opts.expectedAppId, opts.trustedAikFingerprints ?? []),
  );
  return verifiers;
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
    case "untrusted":
      return new HttpsError("permission-denied", "The attestation key is not a trusted attestation identity.");
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
  };
}

function clampTtl(raw: unknown): number {
  if (typeof raw !== "number" || !Number.isFinite(raw)) return DEFAULT_MINT_TTL_MS;
  return Math.min(MAX_MINT_TTL_MS, Math.max(MIN_MINT_TTL_MS, Math.floor(raw)));
}

/** Injectable createToken so the mint path is unit-testable without live Firebase. */
export type AppCheckTokenMinter = (appId: string, options?: AppCheckTokenOptions) => Promise<AppCheckToken>;

interface MintWindowsAppCheckParams {
  claim: unknown;
  verifiers: Map<string, WindowsAttestationVerifier>;
  allowedAppIDs: string[];
  createToken: AppCheckTokenMinter;
  nowMillis: number;
  ttlMillis?: number;
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
async function mintWindowsAppCheckTokenCore(
  params: MintWindowsAppCheckParams,
): Promise<MintWindowsAppCheckResult> {
  const claim = parseAttestationClaim(params.claim);

  // THE FENCE: no verifier for this claim kind ⇒ nothing can prove it ⇒ no mint.
  // Under prod config the registry is empty for a mock claim, so this is the
  // production block — an absent verifier, not a disabled endpoint.
  const verifier = params.verifiers.get(claim.kind);
  if (!verifier) {
    throw new HttpsError(
      "permission-denied",
      "No registered App Check attestation verifier accepted this claim.",
    );
  }

  const result = verifier.verify(claim, params.nowMillis);
  if (!result.ok) {
    throw rejectReasonToError(result.reason);
  }

  if (!isAppCheckAppIdAllowed(result.appId, { allowedAppCheckAppIDs: params.allowedAppIDs })) {
    throw new HttpsError("permission-denied", "App Check app id is not allowlisted.");
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
  buildWindowsAttestationVerifiers,
  mintWindowsAppCheckTokenCore,
  signMockAttestation,
  aikPublicKeyFingerprint,
  MOCK_ATTESTATION_KIND,
  MOCK_ATTESTATION_SHARED_SECRET,
  MOCK_ATTESTATION_MAX_AGE_MS,
  DEFAULT_MINT_TTL_MS,
  makeReplayStore: (): Set<string> => new Set<string>(),
};

/**
 * Read the operator-pinned trusted-AIK fingerprints for the real TPM verifier
 * from the environment (comma/newline separated hex SHA-256 fingerprints). Unset
 * (the current production posture) ⇒ empty ⇒ the TPM verifier fails closed. This
 * is the AC-013 provisioning seam; it is read here rather than added to the typed
 * config surface so the mint path stays self-contained.
 */
function resolveTrustedAikFingerprints(): string[] {
  const raw = process.env.WINDOWS_TPM_AIK_FINGERPRINTS;
  if (typeof raw !== "string" || raw.trim().length === 0) return [];
  return raw
    .split(/[\s,]+/)
    .map((fp) => fp.trim())
    .filter((fp) => fp.length > 0);
}

/** Module-scoped replay store for the deployed callable's mock verifier. */
const moduleReplayStore = new Set<string>();

/** Default minter — resolves the initialized admin app at request time. */
const defaultCreateToken: AppCheckTokenMinter = (appId, options) => getAppCheck().createToken(appId, options);

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
      const input = parseCallableInput("mintWindowsAppCheckToken", {
        ttlMillis: { optional: true, parse: (v: unknown): number | undefined => typeof v === "number" ? v : undefined },
      }, request.data);
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
          trustedAikFingerprints: resolveTrustedAikFingerprints(),
        }),
        allowedAppIDs: config.allowedAppCheckAppIDs,
        createToken: defaultCreateToken,
        nowMillis: Date.now(),
        ttlMillis: typeof input.ttlMillis === "number" ? input.ttlMillis : undefined,
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
