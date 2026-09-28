import assert from "node:assert/strict";
import { test } from "node:test";

import { resolveCampaignActive } from "./seed-promo-campaign.mjs";

test("code-only and policy re-seeds leave a seeded campaign's active flag alone", () => {
  assert.equal(resolveCampaignActive({ deactivateCode: "XOPEN-ULTRA" }, true), undefined);
  assert.equal(resolveCampaignActive({ code: "NEWCODE-2026" }, true), undefined);
  assert.equal(resolveCampaignActive({}, true), undefined);
});

test("--pause and --resume set the flag explicitly", () => {
  assert.equal(resolveCampaignActive({ pause: true }, true), false);
  assert.equal(resolveCampaignActive({ pause: true, deactivateCode: "X" }, true), false);
  assert.equal(resolveCampaignActive({ resume: true }, true), true);
});

test("a first seed creates the campaign active unless paused", () => {
  assert.equal(resolveCampaignActive({}, false), true);
  assert.equal(resolveCampaignActive({ pause: true }, false), false);
});
