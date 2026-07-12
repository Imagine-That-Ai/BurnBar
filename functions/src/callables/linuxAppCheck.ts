/**
 * @fileoverview mintLinuxAppCheckToken — lower-trust Linux desktop App Check bootstrap.
 *
 * Linux cannot use Apple App Attest or Android Play Integrity. The bootstrap
 * path therefore exchanges a platform attestation for a Firebase App Check token
 * minted by Admin SDK. The only verifier implemented here is a non-production
 * fixture verifier; production registers no mock verifier and therefore fails
 * closed until a real distro/package/hardware attestation verifier is configured.
 */

import { createHash, timingSafeEqual } from "node:crypto";

import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { getAppCheck } from "firebase-admin/app-check";
import type { AppCheckToken, AppCheckTokenOptions } from "firebase-admin/app-check";

import { assertAuth } from "../auth.js";
import { getConfig, isAppCheckAppIdAllowed } from "../config.js";
import { isRecord } from "../guards.js";
import { logInfo, wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";
import { checkPublicHttpEndpointRateLimit } from "./publicRateLimit.js";
import { parseCallableInput } from "../validation/callableSchema.js";

const MOCK_ATTESTATION_KIND = "mock" as const;
const MOCK_ATTESTATION_DOMAIN = "openburnbar.appcheck.linux.mock.v1";
const MOCK_ATTESTATION_SHARED_SECRET = "openburnbar-linux-appcheck-mock-fixture-secret";
const MOCK_ATTESTATION_MAX_AGE_MS = 5 * 60 * 1000;
const MOCK_ATTESTATION_CLOCK_SKEW_MS = 60 * 1000;
const DEFAULT_MINT_TTL_MS = 30 * 60 * 1000;
const MIN_MINT_TTL_MS = 30 * 60 * 1000;
const MAX_MINT_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const MIN_NONCE_LENGTH = 16;
const MAX_NONCE_LENGTH = 256;

export interface LinuxAttestationClaim {
  kind: string;
  appId: string;
  nonce: string;
  issuedAtMs: number;
  mac: string;
}

type AttestationRejectReason =
  | "malformed"
  | "app_id_not_expected"
  | "stale"
  | "forged"
  | "replayed";

type VerifyResult = { ok: true; appId: string } | { ok: false; reason: AttestationRejectReason };

export interface LinuxAttestationVerifier {
  readonly kind: string;
  verify(claim: LinuxAttestationClaim, nowMillis: number): VerifyResult;
}

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
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  return timingSafeEqual(Buffer.from(a), Buffer.from(b));
}

class MockLinuxAttestationVerifier implements LinuxAttestationVerifier {
  readonly kind = MOCK_ATTESTATION_KIND;

  constructor(
    private readonly expectedAppId: string,
    private readonly sharedSecret: string = MOCK_ATTESTATION_SHARED_SECRET,
    private readonly consumedNonces: Set<string> = new Set<string>(),
  ) {}

  verify(claim: LinuxAttestationClaim, nowMillis: number): VerifyResult {
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
    if (claim.appId !== this.expectedAppId) return { ok: false, reason: "app_id_not_expected" };
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
    if (!macsEqual(expectedMac, claim.mac)) return { ok: false, reason: "forged" };
    if (this.consumedNonces.has(claim.nonce)) return { ok: false, reason: "replayed" };
    this.consumedNonces.add(claim.nonce);
    return { ok: true, appId: claim.appId };
  }
}

function buildLinuxAttestationVerifiers(opts: {
  allowMock: boolean;
  expectedAppId: string;
  sharedSecret?: string;
  replayStore?: Set<string>;
}): Map<string, LinuxAttestationVerifier> {
  const verifiers = new Map<string, LinuxAttestationVerifier>();
  if (opts.allowMock) {
    verifiers.set(
      MOCK_ATTESTATION_KIND,
      new MockLinuxAttestationVerifier(opts.expectedAppId, opts.sharedSecret, opts.replayStore),
    );
  }
  return verifiers;
}

function rejectReasonToError(reason: AttestationRejectReason): HttpsError {
  switch (reason) {
    case "malformed":
      return new HttpsError("invalid-argument", "The attestation claim is malformed.");
    case "app_id_not_expected":
      return new HttpsError("permission-denied", "The attestation is bound to an unexpected Linux app id.");
    case "stale":
      return new HttpsError("unauthenticated", "The attestation is stale; request a fresh one.");
    case "forged":
      return new HttpsError("unauthenticated", "The attestation signature did not verify.");
    case "replayed":
      return new HttpsError("unauthenticated", "The attestation nonce was already used.");
  }
}

function parseAttestationClaim(raw: unknown): LinuxAttestationClaim {
  if (!isRecord(raw)) throw new HttpsError("invalid-argument", "An attestation claim is required.");
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

export type AppCheckTokenMinter = (appId: string, options?: AppCheckTokenOptions) => Promise<AppCheckToken>;

interface MintLinuxAppCheckParams {
  claim: unknown;
  verifiers: Map<string, LinuxAttestationVerifier>;
  allowedAppIDs: string[];
  createToken: AppCheckTokenMinter;
  nowMillis: number;
  ttlMillis?: number;
}

interface MintLinuxAppCheckResult {
  appCheckToken: string;
  ttlMillis: number;
  appId: string;
}

async function mintLinuxAppCheckTokenCore(params: MintLinuxAppCheckParams): Promise<MintLinuxAppCheckResult> {
  const claim = parseAttestationClaim(params.claim);
  const verifier = params.verifiers.get(claim.kind);
  if (!verifier) {
    throw new HttpsError("permission-denied", "No registered Linux App Check attestation verifier accepted this claim.");
  }

  const result = verifier.verify(claim, params.nowMillis);
  if (!result.ok) throw rejectReasonToError(result.reason);
  if (!isAppCheckAppIdAllowed(result.appId, { allowedAppCheckAppIDs: params.allowedAppIDs })) {
    throw new HttpsError("permission-denied", "Linux App Check app id is not allowlisted.");
  }

  const ttlMillis = clampTtl(params.ttlMillis);
  const token = await params.createToken(result.appId, { ttlMillis });
  return { appCheckToken: token.token, ttlMillis: token.ttlMillis, appId: result.appId };
}

export const __testing__ = {
  MockLinuxAttestationVerifier,
  buildLinuxAttestationVerifiers,
  mintLinuxAppCheckTokenCore,
  signMockAttestation,
  MOCK_ATTESTATION_KIND,
  MOCK_ATTESTATION_MAX_AGE_MS,
  DEFAULT_MINT_TTL_MS,
  makeReplayStore: (): Set<string> => new Set<string>(),
};

const moduleReplayStore = new Set<string>();
const defaultCreateToken: AppCheckTokenMinter = (appId, options) => getAppCheck().createToken(appId, options);

export const mintLinuxAppCheckToken = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: false,
    maxInstances: 20,
  },
  wrapCallableHandler(
    "mintLinuxAppCheckToken",
    async (request: CallableRequest<{ attestation?: unknown; ttlMillis?: unknown }>) => {
      const uid = request.auth?.uid;
      if (!uid) throw new HttpsError("unauthenticated", "Sign in before requesting a Linux App Check token.");
      assertAuth(request);
      await checkPublicHttpEndpointRateLimit("mintLinuxAppCheckToken", uid);

      const input = parseCallableInput("mintLinuxAppCheckToken", {
        ttlMillis: { optional: true, parse: (v: unknown): number | undefined => typeof v === "number" ? v : undefined },
      }, request.data);
      if (request.data?.attestation === undefined) {
        throw new HttpsError("invalid-argument", "mintLinuxAppCheckToken: attestation is required.");
      }

      const config = getConfig();
      const result = await mintLinuxAppCheckTokenCore({
        claim: request.data?.attestation,
        verifiers: buildLinuxAttestationVerifiers({
          allowMock: config.allowMockAppCheckAttestation,
          expectedAppId: config.linuxAppCheckAppID,
          replayStore: moduleReplayStore,
        }),
        allowedAppIDs: config.allowedAppCheckAppIDs,
        createToken: defaultCreateToken,
        nowMillis: Date.now(),
        ttlMillis: typeof input.ttlMillis === "number" ? input.ttlMillis : undefined,
      });

      logInfo({
        event: "callable_info",
        message: "linux_app_check_token_minted",
        app_id: result.appId,
        ttl_millis: result.ttlMillis,
        trust_class: "linux_lower_trust",
      });

      return { ok: true, ...result, trustClass: "linux_lower_trust" };
    },
  ),
);
