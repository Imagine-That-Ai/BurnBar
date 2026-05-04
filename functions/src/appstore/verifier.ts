/**
 * @fileoverview Apple App Store JWS verifier.
 *
 * Wraps `@apple/app-store-server-library`'s `SignedDataVerifier` so the
 * rest of the codebase never has to think about chain construction,
 * environment selection, or trust-anchor pinning.
 *
 * The verifier is a singleton **per environment** because:
 *   - Building it loads three DER root certificates and parses them.
 *   - The library caches verified intermediate public keys for OCSP
 *     reuse; we want that cache to survive across requests in a warm
 *     instance.
 *   - Sandbox testers occasionally hit a production webhook URL (Apple
 *     does not segregate them at the URL layer), so we need both
 *     verifiers ready at all times.
 *
 * Key invariants enforced at construction:
 *
 *   1. The three vendored Apple root certificates each match a SHA-256
 *      fingerprint pinned in `ROOT_FINGERPRINTS_HEX`. A mismatch fails
 *      function cold start before any JWS is trusted.
 *
 *   2. `bundleId` is non-empty; the library will reject any JWS whose
 *      embedded bundleId does not match.
 *
 *   3. `enableOnlineChecks` is honored. Default `true` performs OCSP
 *      revocation checks and signing-cert validity-window enforcement
 *      against the current clock. Tests can disable this without losing
 *      chain validation.
 */

import { createHash, X509Certificate } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

import {
  Environment,
  SignedDataVerifier,
  VerificationException,
  VerificationStatus,
} from "@apple/app-store-server-library";
import type {
  AppTransaction,
  JWSRenewalInfoDecodedPayload,
  JWSTransactionDecodedPayload,
  ResponseBodyV2DecodedPayload,
} from "@apple/app-store-server-library";

import type { AppStoreConfig, AppStoreEnvironment } from "../types.js";

// ---------------------------------------------------------------------------
// Pinned trust anchors
// ---------------------------------------------------------------------------

const HERE = __dirname;

/** Vendored Apple root certificates and their pinned SHA-256 fingerprints. */
export const ROOT_CERT_FILES: ReadonlyArray<{
  name: string;
  fingerprintHex: string;
}> = [
  {
    name: "AppleRootCA-G3.cer",
    fingerprintHex:
      "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
  },
  {
    name: "AppleRootCA-G2.cer",
    fingerprintHex:
      "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
  },
  {
    name: "AppleIncRootCertificate.cer",
    fingerprintHex:
      "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
  },
];

let cachedRootBuffers: Buffer[] | undefined;

/**
 * Read the vendored Apple root certificates, verify each SHA-256
 * fingerprint, and return the DER buffers in the order pinned above.
 *
 * Throws on the first mismatch; operators should treat that as "stop
 * shipping until the cert vendoring story is sorted out".
 */
export function loadAppleRootCertificates(): Buffer[] {
  if (cachedRootBuffers) return cachedRootBuffers;
  const buffers: Buffer[] = [];
  for (const { name, fingerprintHex } of ROOT_CERT_FILES) {
    const libPath = join(HERE, "certs", name);
    const srcPath = join(process.cwd(), "src", "appstore", "certs", name);
    const buf = readFileSync(existsSync(libPath) ? libPath : srcPath);
    const got = createHash("sha256").update(buf).digest("hex");
    if (got !== fingerprintHex) {
      throw new Error(
        `Apple root certificate fingerprint mismatch for ${name}: ` +
          `expected ${fingerprintHex}, got ${got}. Refusing to start.`
      );
    }
    // Quick sanity check that the bytes are a parseable X.509 cert.
    // This will throw if the file is corrupted before we hand the buffer
    // to the Apple library.
    new X509Certificate(buf);
    buffers.push(buf);
  }
  cachedRootBuffers = buffers;
  return buffers;
}

// ---------------------------------------------------------------------------
// Environment mapping
// ---------------------------------------------------------------------------

export function toLibEnvironment(env: AppStoreEnvironment): Environment {
  switch (env) {
    case "Production":
      return Environment.PRODUCTION;
    case "Sandbox":
      return Environment.SANDBOX;
    case "Xcode":
      return Environment.XCODE;
    case "LocalTesting":
      return Environment.LOCAL_TESTING;
  }
}

export function fromLibEnvironment(
  env: Environment | string | undefined
): AppStoreEnvironment | undefined {
  switch (env) {
    case Environment.PRODUCTION:
    case "Production":
      return "Production";
    case Environment.SANDBOX:
    case "Sandbox":
      return "Sandbox";
    case Environment.XCODE:
    case "Xcode":
      return "Xcode";
    case Environment.LOCAL_TESTING:
    case "LocalTesting":
      return "LocalTesting";
    default:
      return undefined;
  }
}

// ---------------------------------------------------------------------------
// AppleJWSVerifier
// ---------------------------------------------------------------------------

export interface VerifyAutoEnvResult<T> {
  payload: T;
  environment: AppStoreEnvironment;
}

/**
 * Decoded view of a JWS. The library exposes payload-only types; we
 * keep the raw token alongside so the reconciler/audit layers can hash
 * the original input without re-stringifying decoded fields.
 */
export interface DecodedTransaction {
  raw: string;
  payload: JWSTransactionDecodedPayload;
  environment: AppStoreEnvironment;
}

export interface DecodedRenewalInfo {
  raw: string;
  payload: JWSRenewalInfoDecodedPayload;
  environment: AppStoreEnvironment;
}

export interface DecodedNotification {
  raw: string;
  payload: ResponseBodyV2DecodedPayload;
  environment: AppStoreEnvironment;
}

export interface DecodedAppTransaction {
  raw: string;
  payload: AppTransaction;
  environment: AppStoreEnvironment;
}

/** A `VerificationException` with friendly stable error codes. */
export class JWSVerificationFailure extends Error {
  readonly status: VerificationStatus;
  readonly cause?: Error;
  constructor(status: VerificationStatus, message: string, cause?: Error) {
    super(message);
    this.name = "JWSVerificationFailure";
    this.status = status;
    this.cause = cause;
  }
}

/** Convert library exception → our stable error. Never silently swallow. */
function rethrow(err: unknown, where: string): never {
  if (err instanceof VerificationException) {
    throw new JWSVerificationFailure(
      err.status,
      `apple-jws-${stableErrorCode(err.status)}: ${where}`,
      err.cause
    );
  }
  throw err;
}

function stableErrorCode(status: VerificationStatus): string {
  switch (status) {
    case VerificationStatus.OK:
      return "ok";
    case VerificationStatus.VERIFICATION_FAILURE:
      return "chain_invalid";
    case VerificationStatus.RETRYABLE_VERIFICATION_FAILURE:
      return "retryable";
    case VerificationStatus.INVALID_APP_IDENTIFIER:
      return "bundle_or_app_id_mismatch";
    case VerificationStatus.INVALID_ENVIRONMENT:
      return "env_mismatch";
    case VerificationStatus.INVALID_CHAIN_LENGTH:
      return "chain_length_invalid";
    case VerificationStatus.INVALID_CERTIFICATE:
      return "leaf_or_intermediate_invalid";
    case VerificationStatus.FAILURE:
    default:
      return "failure";
  }
}

/**
 * Verifier façade. One instance is created per Apple environment we
 * care about and reused across calls.
 */
export class AppleJWSVerifier {
  private readonly cfg: AppStoreConfig;
  private readonly verifiers: Map<AppStoreEnvironment, SignedDataVerifier> =
    new Map();

  constructor(cfg: AppStoreConfig) {
    if (!cfg.bundleId) {
      throw new Error("AppleJWSVerifier requires a non-empty bundleId");
    }
    this.cfg = cfg;
  }

  /** Default environment as configured (used when `signedData` lacks one). */
  get defaultEnvironment(): AppStoreEnvironment {
    return this.cfg.environment;
  }

  /** Lazily build a per-env library verifier. */
  private verifierFor(env: AppStoreEnvironment): SignedDataVerifier {
    const cached = this.verifiers.get(env);
    if (cached) return cached;
    const roots = loadAppleRootCertificates();
    // `appAppleId` is required for Production-environment notification
    // verification but harmless / ignored for sandbox-only flows.
    const verifier = new SignedDataVerifier(
      roots,
      this.cfg.enableOnlineChecks,
      toLibEnvironment(env),
      this.cfg.bundleId,
      env === "Production" ? this.cfg.appAppleId : this.cfg.appAppleId
    );
    this.verifiers.set(env, verifier);
    return verifier;
  }

  /** Hydrate every environment up-front (cold-start pre-warm). */
  warmUp(): void {
    this.verifierFor("Production");
    this.verifierFor("Sandbox");
  }

  // -------------------------------------------------------------------------
  // Notifications V2
  // -------------------------------------------------------------------------

  /**
   * Verify a server-to-server `signedPayload`. Tries the configured
   * environment first; if `autoFallbackEnvironment` is enabled and the
   * embedded `data.environment` claim points to the other environment,
   * retries with that verifier.
   */
  async verifyNotification(signedPayload: string): Promise<DecodedNotification> {
    const primary = this.cfg.environment;
    try {
      const payload =
        await this.verifierFor(primary).verifyAndDecodeNotification(
          signedPayload
        );
      return {
        raw: signedPayload,
        payload,
        environment: fromLibEnvironment(payload.data?.environment) ?? primary,
      };
    } catch (err) {
      if (
        this.cfg.autoFallbackEnvironment &&
        err instanceof VerificationException &&
        (err.status === VerificationStatus.INVALID_ENVIRONMENT ||
          err.status === VerificationStatus.INVALID_APP_IDENTIFIER)
      ) {
        const fallback: AppStoreEnvironment =
          primary === "Production" ? "Sandbox" : "Production";
        try {
          const payload =
            await this.verifierFor(fallback).verifyAndDecodeNotification(
              signedPayload
            );
          return {
            raw: signedPayload,
            payload,
            environment:
              fromLibEnvironment(payload.data?.environment) ?? fallback,
          };
        } catch (e2) {
          rethrow(e2, "verifyNotification[fallback]");
        }
      }
      rethrow(err, "verifyNotification");
    }
  }

  // -------------------------------------------------------------------------
  // Transactions / renewal info
  // -------------------------------------------------------------------------

  async verifyTransaction(
    signedTransaction: string,
    env: AppStoreEnvironment = this.cfg.environment
  ): Promise<DecodedTransaction> {
    try {
      const payload =
        await this.verifierFor(env).verifyAndDecodeTransaction(
          signedTransaction
        );
      return {
        raw: signedTransaction,
        payload,
        environment: fromLibEnvironment(payload.environment) ?? env,
      };
    } catch (err) {
      if (
        this.cfg.autoFallbackEnvironment &&
        err instanceof VerificationException &&
        (err.status === VerificationStatus.INVALID_ENVIRONMENT ||
          err.status === VerificationStatus.INVALID_APP_IDENTIFIER)
      ) {
        const fallback: AppStoreEnvironment =
          env === "Production" ? "Sandbox" : "Production";
        try {
          const payload =
            await this.verifierFor(fallback).verifyAndDecodeTransaction(
              signedTransaction
            );
          return {
            raw: signedTransaction,
            payload,
            environment: fromLibEnvironment(payload.environment) ?? fallback,
          };
        } catch (e2) {
          rethrow(e2, "verifyTransaction[fallback]");
        }
      }
      rethrow(err, "verifyTransaction");
    }
  }

  async verifyRenewalInfo(
    signedRenewalInfo: string,
    env: AppStoreEnvironment = this.cfg.environment
  ): Promise<DecodedRenewalInfo> {
    try {
      const payload =
        await this.verifierFor(env).verifyAndDecodeRenewalInfo(
          signedRenewalInfo
        );
      return {
        raw: signedRenewalInfo,
        payload,
        environment: fromLibEnvironment(payload.environment) ?? env,
      };
    } catch (err) {
      if (
        this.cfg.autoFallbackEnvironment &&
        err instanceof VerificationException &&
        (err.status === VerificationStatus.INVALID_ENVIRONMENT ||
          err.status === VerificationStatus.INVALID_APP_IDENTIFIER)
      ) {
        const fallback: AppStoreEnvironment =
          env === "Production" ? "Sandbox" : "Production";
        try {
          const payload =
            await this.verifierFor(fallback).verifyAndDecodeRenewalInfo(
              signedRenewalInfo
            );
          return {
            raw: signedRenewalInfo,
            payload,
            environment: fromLibEnvironment(payload.environment) ?? fallback,
          };
        } catch (e2) {
          rethrow(e2, "verifyRenewalInfo[fallback]");
        }
      }
      rethrow(err, "verifyRenewalInfo");
    }
  }

  // -------------------------------------------------------------------------
  // App transactions
  // -------------------------------------------------------------------------

  async verifyAppTransaction(
    signedAppTransaction: string,
    env: AppStoreEnvironment = this.cfg.environment
  ): Promise<DecodedAppTransaction> {
    try {
      const payload =
        await this.verifierFor(env).verifyAndDecodeAppTransaction(
          signedAppTransaction
        );
      return {
        raw: signedAppTransaction,
        payload,
        environment: fromLibEnvironment(payload.receiptType) ?? env,
      };
    } catch (err) {
      rethrow(err, "verifyAppTransaction");
    }
  }
}

// ---------------------------------------------------------------------------
// Singleton accessor
// ---------------------------------------------------------------------------

let cachedVerifier:
  | { cfg: AppStoreConfig; verifier: AppleJWSVerifier }
  | undefined;

/**
 * Get the process-singleton verifier. The cached instance is rebuilt if
 * the supplied config differs from the previous one (rare; matters only
 * when tests inject overrides).
 */
export function getAppleJWSVerifier(cfg: AppStoreConfig): AppleJWSVerifier {
  if (
    cachedVerifier &&
    cachedVerifier.cfg.bundleId === cfg.bundleId &&
    cachedVerifier.cfg.environment === cfg.environment &&
    cachedVerifier.cfg.appAppleId === cfg.appAppleId &&
    cachedVerifier.cfg.enableOnlineChecks === cfg.enableOnlineChecks &&
    cachedVerifier.cfg.autoFallbackEnvironment === cfg.autoFallbackEnvironment
  ) {
    return cachedVerifier.verifier;
  }
  const verifier = new AppleJWSVerifier(cfg);
  cachedVerifier = { cfg, verifier };
  return verifier;
}
