/**
 * @fileoverview App Store Server API client wrapper.
 *
 * Wraps `AppStoreServerAPIClient` so the rest of the codebase only sees
 * a single typed entry point: `getAppStoreServerAPIClient(cfg)`.
 *
 * Why a wrapper:
 *   - The library client is environment-bound at construction. We need
 *     parallel Production and Sandbox clients because subscription
 *     reconciliation may target either.
 *   - Live JWS responses (`signedTransactionInfo`, `signedRenewalInfo`)
 *     must be re-verified by *our* `AppleJWSVerifier` rather than blindly
 *     trusted as decoded JSON from a TLS connection.
 *   - We surface only the methods the entitlement reconciler needs,
 *     keeping cross-module API surface tight.
 */

import {
  AppStoreServerAPIClient,
  Environment,
  type StatusResponse,
  type TransactionInfoResponse,
} from "@apple/app-store-server-library";

import type { AppStoreConfig, AppStoreEnvironment } from "../types.js";
import { toLibEnvironment } from "./verifier.js";

interface ClientCacheKey {
  bundleId: string;
  environment: AppStoreEnvironment;
  keyId: string;
  issuerId: string;
  privateKeyP8: string;
}

const cache = new Map<string, AppStoreServerAPIClient>();

function cacheKey(k: ClientCacheKey): string {
  // Hashing by reference identity isn't safe across cold starts; the
  // private key is identity-bearing for ASC and rotates rarely, so its
  // first 32 chars are a safe disambiguator without log-leaking it.
  const fingerprint = k.privateKeyP8.slice(0, 32);
  return `${k.bundleId}|${k.environment}|${k.keyId}|${k.issuerId}|${fingerprint}`;
}

/**
 * Build (or fetch from cache) an `AppStoreServerAPIClient` for the given
 * environment. `cfg.asc.privateKeyP8` must be a complete PEM body.
 */
export function getAppStoreServerAPIClient(
  cfg: AppStoreConfig,
  environment: AppStoreEnvironment = cfg.environment
): AppStoreServerAPIClient {
  if (!cfg.bundleId) throw new Error("bundleId is required");
  if (!cfg.asc.keyId) throw new Error("ASC keyId is required");
  if (!cfg.asc.issuerId) throw new Error("ASC issuerId is required");
  if (!cfg.asc.privateKeyP8 || !cfg.asc.privateKeyP8.includes("PRIVATE KEY")) {
    throw new Error("ASC privateKeyP8 must be a PEM body");
  }
  const key: ClientCacheKey = {
    bundleId: cfg.bundleId,
    environment,
    keyId: cfg.asc.keyId,
    issuerId: cfg.asc.issuerId,
    privateKeyP8: cfg.asc.privateKeyP8,
  };
  const ck = cacheKey(key);
  const cached = cache.get(ck);
  if (cached) return cached;
  const client = new AppStoreServerAPIClient(
    cfg.asc.privateKeyP8,
    cfg.asc.keyId,
    cfg.asc.issuerId,
    cfg.bundleId,
    toLibEnvironment(environment)
  );
  cache.set(ck, client);
  return client;
}

/**
 * Pair of raw JWS strings we expect for any subscription line item.
 * The reconciler re-verifies each through `AppleJWSVerifier` before
 * trusting any decoded field.
 */
export interface SignedSubscriptionPair {
  signedTransactionInfo: string;
  signedRenewalInfo?: string;
}

/**
 * Look up live subscription status for an `originalTransactionId` and
 * return the raw signed JWS pairs Apple returned. The caller is the
 * one re-verifying these tokens — the wrapper deliberately does not
 * decode them.
 */
export async function fetchLiveSubscriptionStatus(
  cfg: AppStoreConfig,
  environment: AppStoreEnvironment,
  originalTransactionId: string
): Promise<{ status: StatusResponse; pairs: SignedSubscriptionPair[] }> {
  const client = getAppStoreServerAPIClient(cfg, environment);
  const status = await client.getAllSubscriptionStatuses(originalTransactionId);
  const pairs: SignedSubscriptionPair[] = [];
  for (const group of status.data ?? []) {
    for (const item of group.lastTransactions ?? []) {
      if (!item.signedTransactionInfo) continue;
      pairs.push({
        signedTransactionInfo: item.signedTransactionInfo,
        signedRenewalInfo: item.signedRenewalInfo,
      });
    }
  }
  return { status, pairs };
}

/**
 * Fetch the latest known transaction info for a given transaction id.
 * Useful when we have only a transactionId (not original) and need to
 * dereference its current signed payload.
 */
export async function fetchLatestTransactionInfo(
  cfg: AppStoreConfig,
  environment: AppStoreEnvironment,
  transactionId: string
): Promise<TransactionInfoResponse> {
  const client = getAppStoreServerAPIClient(cfg, environment);
  return client.getTransactionInfo(transactionId);
}

/** Convenience: shape compatibility for tests that mock `Environment`. */
export const ASC_ENVIRONMENT = Environment;
