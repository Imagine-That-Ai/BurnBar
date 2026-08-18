#!/usr/bin/env node
import { readJson, runCheckCli } from './lib/check-support.mjs';
import {
  authSessionState,
  classifyAuthError,
  classifyCancellation,
  classifyError,
  classifyEscrowImport,
  effectiveTier,
  providerConnectivity,
  quotaStatus,
  shouldApplyRefresh,
  shouldServeCachedUid,
  storeEntitlementState,
  storePriceDisplay,
  syncFreshness,
  validateDeviceTrust,
  validateEnvelopeAad,
  validateRelayChunks,
  validateWindowKey
} from './lib/mobile-policy-vectors.mjs';
import { repoRoot } from './lib/repo-root.mjs';

export const POLICY_VECTORS_PATH = 'docs/mobile-parity/fixtures/policy/mobile-policy-vectors.json';

export function validateMobilePolicyVectors(options = {}) {
  const failures = [];
  const root = options.repoRoot ?? repoRoot;
  const document = readJson(root, options.path ?? POLICY_VECTORS_PATH, 'missing policy vectors:');
  if (document.error) return { passed: false, failures: [document.error] };
  const suites = document.value.suites ?? {};

  for (const key of suites.usageWindows?.valid ?? []) {
    if (!validateWindowKey(key)) failures.push(`usage window ${key} should be valid`);
  }
  for (const key of suites.usageWindows?.invalid ?? []) {
    if (validateWindowKey(key)) failures.push(`usage window ${key} should be invalid`);
  }

  for (const row of suites.quotaStatus ?? []) {
    const result = quotaStatus(row.used, row.limit);
    if (row.failClosed && !result.failClosed) failures.push(`quota ${row.id} should fail closed`);
    if (result.remaining !== row.expectedRemaining || result.pressure !== row.expectedPressure) {
      failures.push(`quota ${row.id} remaining/pressure mismatch`);
    }
  }

  for (const row of suites.entitlementGates ?? []) {
    const tier = effectiveTier(row.cloud, row.storeKit, row.now);
    if (tier !== row.expectedTier) failures.push(`entitlement ${row.id} expected ${row.expectedTier} got ${tier}`);
  }

  for (const row of suites.deviceTrust ?? []) {
    if (validateDeviceTrust(row.trustState, row.deviceId) !== row.ok) {
      failures.push(`device trust ${row.id} mismatch`);
    }
  }

  for (const row of suites.envelopeAad ?? []) {
    if (validateEnvelopeAad(row.expected, row.observed) !== row.ok) {
      failures.push(`envelope AAD ${row.id} mismatch`);
    }
  }

  for (const row of suites.relayChunks ?? []) {
    if (validateRelayChunks(row.sequences, row.declaredChunkCount) !== row.ok) {
      failures.push(`relay chunks ${row.id} mismatch`);
    }
  }

  for (const row of suites.errorClasses ?? []) {
    if (classifyError(row.code) !== row.expected) failures.push(`error class ${row.id} mismatch`);
  }

  for (const row of suites.cancellationLegacy ?? []) {
    if (classifyCancellation(row.status, row.legacyFallback) !== row.expected) {
      failures.push(`cancellation ${row.id} mismatch`);
    }
  }

  for (const row of suites.authSession ?? []) {
    if (authSessionState(row.firebaseAvailable, row.signedIn) !== row.expected) {
      failures.push(`auth session ${row.id} mismatch`);
    }
  }
  for (const row of suites.authErrors ?? []) {
    if (classifyAuthError(row.code) !== row.expected) {
      failures.push(`auth error ${row.id} mismatch`);
    }
  }
  for (const row of suites.uidCache ?? []) {
    if (shouldServeCachedUid(row.cacheUid, row.activeUid, row.cacheGeneration, row.activeGeneration) !== row.ok) {
      failures.push(`uid cache ${row.id} mismatch`);
    }
  }
  for (const row of suites.syncFreshness ?? []) {
    if (syncFreshness(row) !== row.expected) failures.push(`sync freshness ${row.id} mismatch`);
  }
  for (const row of suites.syncRefresh ?? []) {
    if (shouldApplyRefresh(row.startedGeneration, row.currentGeneration, row.cancelled) !== row.ok) {
      failures.push(`sync refresh ${row.id} mismatch`);
    }
  }
  for (const row of suites.providerConnectivity ?? []) {
    if (providerConnectivity(row.storageScope) !== row.expected) {
      failures.push(`provider ${row.id} mismatch`);
    }
  }
  for (const row of suites.escrowImport ?? []) {
    if (classifyEscrowImport(row) !== row.expected) failures.push(`escrow ${row.id} mismatch`);
  }
  for (const row of suites.storePrices ?? []) {
    if (storePriceDisplay(row.livePrice) !== row.expected) failures.push(`store price ${row.id} mismatch`);
  }
  for (const row of suites.storeEntitlements ?? []) {
    if (storeEntitlementState(row) !== row.expected) failures.push(`store entitlement ${row.id} mismatch`);
  }

  return { passed: failures.length === 0, failures };
}

runCheckCli(import.meta.url, validateMobilePolicyVectors, () => 'mobile policy vectors ok');
