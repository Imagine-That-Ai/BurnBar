#!/usr/bin/env node
import assert from "node:assert/strict";

import { Timestamp } from "firebase-admin/firestore";

import { buildTierCogsDailyDoc, TIER_COGS_UNIT_COSTS } from "../lib/tierCogs.js";

const doc = buildTierCogsDailyDoc(
  {
    dayKey: "2026-05-30",
    cloud: {
      activeSubscribers: 10,
      dailyBaseCogsUSD: 0.008,
      netRevenuePerSubscriberDayUSD: 0.2263833333,
    },
    cloudPro: {
      activeSubscribers: 2,
      dailyBaseCogsUSD: 0.008,
      mediaRelayCogsUSD: 1.2,
      hostedVisionCogsUSD: 3.4,
      netRevenuePerSubscriberDayUSD: 0.70805,
    },
  },
  Timestamp.fromDate(new Date("2026-05-31T01:15:00Z")),
);

assert.equal(doc.id, "2026-05-30");
assert.equal(doc.dayKey, "2026-05-30");
assert.equal(doc.unitCosts.hostedVisionActionUSD, TIER_COGS_UNIT_COSTS.hostedVisionActionUSD);
assert.equal(doc.cloud.activeSubscribers, 10);
assert.equal(doc.cloud.netRevenueUSD, 2.2638);
assert.equal(doc.cloud.cogsUSD, 0.08);
assert.equal(doc.cloud.grossMarginRatio, 0.9647);
assert.equal(doc.cloudPro.activeSubscribers, 2);
assert.equal(doc.cloudPro.netRevenueUSD, 1.4161);
assert.equal(doc.cloudPro.cogsUSD, 4.616);
assert.equal(doc.cloudPro.mediaRelayCogsUSD, undefined);
assert.equal(doc.mediaRelayCogsUSD, 1.2);
assert.equal(doc.hostedVisionCogsUSD, 3.4);
assert.equal(doc.cloudPro.grossMarginRatio, -2.2597);
assert.equal(doc.schemaVersion, 1);

console.log("Tier COGS daily document fixture passed.");
