#!/usr/bin/env node
/**
 * Unit tests for two-tier commercial launch-gate requirement evaluators.
 */

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  COMMERCIAL_PRODUCTS,
  evaluateAppStoreProductReadiness,
  evaluateEnvRequirements,
  evaluateRemoteConfigDefaults,
  evaluateRequiredProductIDs,
  verdict,
} from "./commercial-launch-gate.mjs";

const launchGateSource = readFileSync(new URL("./commercial-launch-gate.mjs", import.meta.url), "utf8");
assert.match(launchGateSource, /verifyCloudProTopUp/);
assert.match(launchGateSource, /verifyGooglePlayCloudProTopUp/);
assert.match(launchGateSource, /READY_FOR_CANARY/);
assert.match(launchGateSource, /READY_FOR_PUBLIC_RELEASE/);
assert.match(launchGateSource, /LAUNCH_DONE/);
assert.match(launchGateSource, /prove:paid-tier/);
assert.match(launchGateSource, /validateLaunchEvidenceBundle/);

function passingChecks(overrides = {}) {
  return {
    repo: { ok: true },
    appStore: { ok: true, state: "READY_FOR_SALE" },
    appStoreServerNotifications: { ok: true },
    firebaseAppCheck: { ok: true },
    branchProtection: { ok: true },
    githubSecurity: { ok: true },
    mainRequiredGate: { ok: true },
    mainCodeQL: { ok: true },
    latestMergedPrGate: { ok: true },
    cloudRun: { ok: true },
    runnerReadyz: { ok: true },
    redis: { ok: true },
    hostedQuotaRuntime: { ok: true },
    commercialBillingRuntime: { ok: true },
    remoteConfigCaps: { ok: true },
    opsAlerts: { ok: true },
    billingAlerts: { ok: true },
    firebaseFunctionsInventory: { ok: true },
    launchEvidence: {
      ok: true,
      stages: {
        paidProof: { ok: false, skipped: true },
        publicRelease: { ok: false, skipped: true },
        done: { ok: false, skipped: true },
      },
    },
    ...overrides,
  };
}

{
  assert.equal(verdict(passingChecks()).status, "READY_FOR_LIVE_PAID_PROOF");
  assert.equal(
    verdict(
      passingChecks({
        launchEvidence: {
          ok: true,
          stages: {
            paidProof: { ok: true },
            publicRelease: { ok: false },
            done: { ok: false },
          },
        },
      }),
    ).status,
    "READY_FOR_CANARY",
  );
  assert.equal(
    verdict(
      passingChecks({
        launchEvidence: {
          ok: true,
          stages: {
            paidProof: { ok: true },
            publicRelease: { ok: true },
            done: { ok: false },
          },
        },
      }),
    ).status,
    "READY_FOR_PUBLIC_RELEASE",
  );
  assert.equal(
    verdict(
      passingChecks({
        launchEvidence: {
          ok: true,
          stages: {
            paidProof: { ok: true },
            publicRelease: { ok: true },
            done: { ok: true },
          },
        },
      }),
    ).status,
    "LAUNCH_DONE",
  );
  assert.equal(verdict(passingChecks({ billingAlerts: { ok: false } })).status, "NO_GO");
}

{
  const coverage = evaluateRequiredProductIDs(
    [
      COMMERCIAL_PRODUCTS.cloudMonthly,
      COMMERCIAL_PRODUCTS.cloudAnnual,
      COMMERCIAL_PRODUCTS.cloudProMonthly,
      COMMERCIAL_PRODUCTS.cloudProAnnual,
      COMMERCIAL_PRODUCTS.agentControlActions100,
      COMMERCIAL_PRODUCTS.flooRelay50GB,
    ],
    [
      COMMERCIAL_PRODUCTS.cloudMonthly,
      COMMERCIAL_PRODUCTS.cloudAnnual,
      COMMERCIAL_PRODUCTS.cloudProMonthly,
      COMMERCIAL_PRODUCTS.cloudProAnnual,
      COMMERCIAL_PRODUCTS.agentControlActions100,
      COMMERCIAL_PRODUCTS.flooRelay50GB,
    ],
  );
  assert.equal(coverage.ok, true);
  assert.deepEqual(coverage.missing, []);
}

{
  const coverage = evaluateRequiredProductIDs(
    [COMMERCIAL_PRODUCTS.cloudMonthly],
    [COMMERCIAL_PRODUCTS.cloudMonthly, COMMERCIAL_PRODUCTS.cloudProMonthly],
  );
  assert.equal(coverage.ok, false);
  assert.deepEqual(coverage.missing, [COMMERCIAL_PRODUCTS.cloudProMonthly]);
}

{
  const readiness = evaluateAppStoreProductReadiness(
    {
      subscriptions: [
        {
          id: "sub_cloud_monthly",
          productId: COMMERCIAL_PRODUCTS.cloudMonthly,
          name: "BurnBar Cloud Monthly",
          state: "READY_TO_SUBMIT",
        },
        {
          id: "sub_cloud_pro_monthly",
          productId: COMMERCIAL_PRODUCTS.cloudProMonthly,
          name: "BurnBar Cloud Pro Monthly",
          state: "APPROVED",
        },
      ],
      inAppPurchases: [
        {
          id: "iap_actions",
          productId: COMMERCIAL_PRODUCTS.agentControlActions100,
          name: "Agent Control 100 Actions",
          state: "WAITING_FOR_REVIEW",
        },
      ],
    },
    [
      COMMERCIAL_PRODUCTS.cloudMonthly,
      COMMERCIAL_PRODUCTS.cloudProMonthly,
      COMMERCIAL_PRODUCTS.agentControlActions100,
    ],
  );
  assert.equal(readiness.ok, true);
}

{
  const readiness = evaluateAppStoreProductReadiness(
    {
      subscriptions: [
        {
          id: "sub_cloud_monthly",
          productId: COMMERCIAL_PRODUCTS.cloudMonthly,
          name: "BurnBar Cloud Monthly",
          state: "MISSING_METADATA",
        },
      ],
    },
    [COMMERCIAL_PRODUCTS.cloudMonthly, COMMERCIAL_PRODUCTS.cloudProMonthly],
  );
  assert.equal(readiness.ok, false);
  assert.deepEqual(
    readiness.checks.map((check) => [check.productId, check.state, check.ok]),
    [
      [COMMERCIAL_PRODUCTS.cloudMonthly, "MISSING_METADATA", false],
      [COMMERCIAL_PRODUCTS.cloudProMonthly, null, false],
    ],
  );
}

{
  const env = {
    STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID: "price_cloud_monthly",
    STRIPE_BURNBAR_PRO_PRICE_ID: "price_cloud_monthly",
    BURNBAR_PRO_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudMonthly,
  };
  const evaluated = evaluateEnvRequirements(
    env,
    {
      STRIPE_BURNBAR_PRO_PRICE_ID: "alias:STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID",
      BURNBAR_PRO_PRODUCT_ID: COMMERCIAL_PRODUCTS.cloudMonthly,
    },
    ["STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID"],
  );
  assert.equal(evaluated.ok, true);
}

{
  const env = {
    STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID: "price_cloud_monthly",
    STRIPE_BURNBAR_PRO_PRICE_ID: "price_legacy",
  };
  const evaluated = evaluateEnvRequirements(
    env,
    {
      STRIPE_BURNBAR_PRO_PRICE_ID: "alias:STRIPE_BURNBAR_CLOUD_MONTHLY_PRICE_ID",
    },
    [],
  );
  assert.equal(evaluated.ok, false);
  assert.equal(evaluated.valueChecks[0].actual, "price_legacy");
}

{
  const template = {
    parameters: {
      media_budget_soft_usd: { defaultValue: { value: "600" } },
      computer_use_budget_hard_usd: { defaultValue: { value: "2500" } },
    },
  };
  const evaluated = evaluateRemoteConfigDefaults(template, {
    media_budget_soft_usd: "600",
    computer_use_budget_hard_usd: "2500",
  });
  assert.equal(evaluated.ok, true);
}

{
  const template = {
    parameters: {
      media_budget_soft_usd: { defaultValue: { value: "500" } },
    },
  };
  const evaluated = evaluateRemoteConfigDefaults(template, {
    media_budget_soft_usd: "600",
  });
  assert.equal(evaluated.ok, false);
  assert.equal(evaluated.checks[0].actual, "500");
}

console.log("commercial-launch-gate commercial evaluator tests passed");
