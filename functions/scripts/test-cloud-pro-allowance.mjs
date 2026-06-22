#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  allowanceDocPath,
  cloudProTopUpReceiptDocPath,
  CLOUD_PRO_ACTION_TOP_UP_UNIT,
  CLOUD_PRO_FUSION_SEARCH_LARGE_TOP_UP_UNIT,
  CLOUD_PRO_FUSION_SEARCH_TOP_UP_UNIT,
  CLOUD_PRO_INCLUDED_HOSTED_ACTIONS_MONTHLY,
  CLOUD_PRO_MONTHLY_HOSTED_ACTION_CAP,
  CLOUD_PRO_RELAY_TOP_UP_UNIT_GB,
  evaluateCloudProAllowanceReservation,
  isMatchingCloudProAllowanceReservation,
  normalizeCloudProAllowanceConfig,
  monthKeyForDate,
  unitsForCloudProTopUp,
} from "../lib/cloudProAllowanceCore.js";

const monthKey = monthKeyForDate(new Date("2026-05-30T12:00:00Z"));
const root = join(dirname(fileURLToPath(import.meta.url)), "..");
assert.equal(monthKey, "2026-05");
assert.equal(allowanceDocPath("user_123", monthKey), "users/user_123/billing/allowances/months/2026-05");
assert.equal(
  cloudProTopUpReceiptDocPath("user_123", "appstore_tx_123"),
  "users/user_123/billing/cloud_pro_topups/receipts/appstore_tx_123",
);

const reservationIdentity = {
  uid: "user_123",
  monthKey,
  meter: "hosted_actions",
  sessionId: "session_1",
  reservationId: "hosted_actions_reservation_1",
  requestedUnits: 3,
};
assert.equal(isMatchingCloudProAllowanceReservation({ ...reservationIdentity }, reservationIdentity), true);
assert.equal(
  isMatchingCloudProAllowanceReservation({ ...reservationIdentity, sessionId: "session_2" }, reservationIdentity),
  false,
);
assert.equal(
  isMatchingCloudProAllowanceReservation({ ...reservationIdentity, requestedUnits: 1 }, reservationIdentity),
  false,
);

const firstReservation = evaluateCloudProAllowanceReservation({
  includedUnits: CLOUD_PRO_INCLUDED_HOSTED_ACTIONS_MONTHLY,
  usedUnits: 0,
  topUpUnits: 0,
  monthlyCap: CLOUD_PRO_MONTHLY_HOSTED_ACTION_CAP,
  requestedUnits: 1,
});
assert.equal(firstReservation.ok, true);
assert.equal(firstReservation.availableUnits, 500);
assert.equal(firstReservation.monthlyCapRemaining, 2000);
assert.equal(firstReservation.usedAfter, 1);

const exhausted = evaluateCloudProAllowanceReservation({
  includedUnits: CLOUD_PRO_INCLUDED_HOSTED_ACTIONS_MONTHLY,
  usedUnits: 500,
  topUpUnits: 0,
  monthlyCap: CLOUD_PRO_MONTHLY_HOSTED_ACTION_CAP,
  requestedUnits: 1,
});
assert.equal(exhausted.ok, false);
assert.equal(exhausted.reason, "allowance_exhausted");

const monthlyCap = evaluateCloudProAllowanceReservation({
  includedUnits: CLOUD_PRO_INCLUDED_HOSTED_ACTIONS_MONTHLY,
  usedUnits: 1999,
  topUpUnits: 2000,
  monthlyCap: CLOUD_PRO_MONTHLY_HOSTED_ACTION_CAP,
  requestedUnits: 2,
});
assert.equal(monthlyCap.ok, false);
assert.equal(monthlyCap.reason, "monthly_cap_exceeded");

assert.deepEqual(unitsForCloudProTopUp("agent_control_actions_100"), {
  meter: "hosted_actions",
  units: CLOUD_PRO_ACTION_TOP_UP_UNIT,
});
assert.deepEqual(unitsForCloudProTopUp("floo_relay_50gb", 2), {
  meter: "relay_gb",
  units: CLOUD_PRO_RELAY_TOP_UP_UNIT_GB * 2,
});
assert.deepEqual(unitsForCloudProTopUp("elder_wand_searches_100"), {
  meter: "fusion_searches",
  units: CLOUD_PRO_FUSION_SEARCH_TOP_UP_UNIT,
});
assert.deepEqual(unitsForCloudProTopUp("elder_wand_searches_500", 2), {
  meter: "fusion_searches",
  units: CLOUD_PRO_FUSION_SEARCH_LARGE_TOP_UP_UNIT * 2,
});

const tunedConfig = normalizeCloudProAllowanceConfig({
  includedHostedActionsMonthly: "250",
  actionTopUpUnit: "50",
  monthlyHostedActionCap: "1000",
  includedRelayGBMonthly: "25",
  relayTopUpUnitGB: "25",
  monthlyRelayGBCap: "150",
  includedFusionSearchesMonthly: "75",
  includedUltraFusionSearchesMonthly: "225",
  fusionSearchTopUpUnit: "75",
  fusionSearchLargeTopUpUnit: "375",
  monthlyFusionSearchCap: "600",
  monthlyUltraFusionSearchCap: "1200",
});
assert.deepEqual(unitsForCloudProTopUp("agent_control_actions_100", 2, tunedConfig), {
  meter: "hosted_actions",
  units: 100,
});
assert.deepEqual(unitsForCloudProTopUp("elder_wand_searches_500", 1, tunedConfig), {
  meter: "fusion_searches",
  units: 375,
});

const invalidConfig = normalizeCloudProAllowanceConfig({
  includedHostedActionsMonthly: "500",
  monthlyHostedActionCap: "100",
});
assert.equal(invalidConfig.monthlyHostedActionCap, CLOUD_PRO_MONTHLY_HOSTED_ACTION_CAP);

const stripeCallableSource = readFileSync(join(root, "src/callables/stripe.ts"), "utf8");
assert.match(stripeCallableSource, /verifyGooglePlayCloudProTopUp/);
assert.match(stripeCallableSource, /purchases\.products\.get/);
assert.match(stripeCallableSource, /purchases\.products\.consume/);
assert.match(stripeCallableSource, /creditCloudProTopUp/);

const entitlementSource = readFileSync(join(root, "src/callables/shared/entitlements.ts"), "utf8");
assert.match(entitlementSource, /isActiveBurnBarCloudProEntitlement/);
assert.match(entitlementSource, /isActiveBurnBarUltraEntitlement\(ultraSnap\.data\(\)\)/);
assert.match(entitlementSource, /ensureCloudProAllowanceLedger/);
assert.match(entitlementSource, /cloudProTopUpReceiptDocPath/);
assert.match(entitlementSource, /existingReceipt\.exists \|\| existingMonthlyTopUp\.exists/);
assert.match(
  entitlementSource,
  /entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID \|\| entitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID/,
);
assert.match(entitlementSource, /cloudProAllowanceTierForEntitlement\(entitlementID, args\.productID\)/);
assert.doesNotMatch(
  entitlementSource,
  /assertActiveBurnBarCloudProEntitlement[\s\S]*isActivePremiumEntitlement\(proMaxSnap\.data\(\)\)/,
);

const sharedStripeSource = readFileSync(join(root, "src/callables/shared/stripe.ts"), "utf8");
assert.match(sharedStripeSource, /return lineItems\.find\(\(item\) => item\.productId === productID\);/);
assert.doesNotMatch(
  sharedStripeSource,
  /lineItems\.find\(\(item\) => item\.productId === productID\) \?\? lineItems\[0\]/,
);

const mediaSkuSource = readFileSync(join(root, "src/callables/mediaSku.ts"), "utf8");
assert.match(mediaSkuSource, /standalone media subscription is retired/i);
assert.doesNotMatch(mediaSkuSource, /media_purchase_validated/);

console.log("Cloud Pro allowance accounting fixtures passed.");
