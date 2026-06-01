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
} from "./commercial-launch-gate.mjs";

const launchGateSource = readFileSync(new URL("./commercial-launch-gate.mjs", import.meta.url), "utf8");
assert.match(launchGateSource, /verifyCloudProTopUp/);
assert.match(launchGateSource, /verifyGooglePlayCloudProTopUp/);
assert.match(launchGateSource, /READY_FOR_CANARY/);
assert.match(launchGateSource, /READY_FOR_PUBLIC_RELEASE/);
assert.match(launchGateSource, /validateLaunchEvidenceBundle/);
assert.match(launchGateSource, /prove:paid-tier for Cloud and Cloud Pro/);
assert.doesNotMatch(
  launchGateSource,
  /Run prove:hosted-quota against a real paid user/,
  "live paid proof gate copy must reference the two-tier paid proof command",
);

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
