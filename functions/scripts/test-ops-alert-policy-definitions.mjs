#!/usr/bin/env node
import assert from "node:assert/strict";

import { OPS_SLO_ALERT_POLICIES } from "./ops-alert-policy-definitions.mjs";

function policy(name) {
  const found = OPS_SLO_ALERT_POLICIES.find((entry) => entry.displayName === name);
  assert.ok(found, `missing policy: ${name}`);
  return found;
}

function conditionFilters(entry) {
  return entry.conditions.map((condition) => condition.conditionThreshold?.filter ?? "");
}

{
  const rollupBreaker = policy("OpenBurnBar Rollup rebuild breaker open");
  const filters = conditionFilters(rollupBreaker);
  assert.equal(filters.length, 2);
  for (const filter of filters) {
    assert.match(filter, /resource\.type="cloud_run_revision"/);
    assert.doesNotMatch(filter, /resource\.type="cloud_function"/);
  }
  assert.ok(filters.some((filter) => filter.includes("openburnbar_rollup_breaker_open")));
  assert.ok(filters.some((filter) => filter.includes("openburnbar_rollup_rebuild_failed")));
}

{
  const deltaCapped = policy("OpenBurnBar Rollup delta drain capped");
  const [filter] = conditionFilters(deltaCapped);
  assert.match(filter, /resource\.type="cloud_run_revision"/);
  assert.doesNotMatch(filter, /resource\.type="cloud_function"/);
  assert.match(filter, /openburnbar_rollup_delta_drain_capped/);
}

{
  const deliveryDrill = policy("OpenBurnBar alert-delivery drill canary");
  assert.equal(deliveryDrill.conditions.length, 1);
  const threshold = deliveryDrill.conditions[0].conditionThreshold;
  assert.equal(threshold?.duration, "0s");
  assert.equal(threshold?.thresholdValue, 0);
  assert.equal(threshold?.aggregations?.[0]?.perSeriesAligner, "ALIGN_DELTA");
}

console.log("ops alert policy definition tests passed");
