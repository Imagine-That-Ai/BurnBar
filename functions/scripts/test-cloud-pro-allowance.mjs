#!/usr/bin/env node
import assert from "node:assert/strict";

import {
  allowanceDocPath,
  CLOUD_PRO_ACTION_TOP_UP_UNIT,
  CLOUD_PRO_INCLUDED_HOSTED_ACTIONS_MONTHLY,
  CLOUD_PRO_MONTHLY_HOSTED_ACTION_CAP,
  CLOUD_PRO_RELAY_TOP_UP_UNIT_GB,
  evaluateCloudProAllowanceReservation,
  monthKeyForDate,
  unitsForCloudProTopUp,
} from "../lib/cloudProAllowanceCore.js";

const monthKey = monthKeyForDate(new Date("2026-05-30T12:00:00Z"));
assert.equal(monthKey, "2026-05");
assert.equal(allowanceDocPath("user_123", monthKey), "users/user_123/billing/allowances/months/2026-05");

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

console.log("Cloud Pro allowance accounting fixtures passed.");
