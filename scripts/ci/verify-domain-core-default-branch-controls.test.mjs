import assert from "node:assert/strict";
import test from "node:test";

import { verifyDefaultBranchControls } from "./verify-domain-core-default-branch-controls.mjs";

function fixture() {
  return {
    required_status_checks: {
      strict: true,
      contexts: ["BurnBar CI Gate"],
    },
    enforce_admins: { enabled: true },
    required_pull_request_reviews: {
      required_approving_review_count: 1,
      dismiss_stale_reviews: true,
    },
    allow_force_pushes: { enabled: false },
    allow_deletions: { enabled: false },
  };
}

test("accepts fail-closed official main protection", () => {
  assert.equal(verifyDefaultBranchControls(fixture()).branch, "main");
});

for (const [name, mutate] of [
  [
    "missing umbrella gate",
    (value) => value.required_status_checks.contexts.pop(),
  ],
  [
    "non-strict checks",
    (value) => (value.required_status_checks.strict = false),
  ],
  ["admin bypass", (value) => (value.enforce_admins.enabled = false)],
  [
    "stale approval",
    (value) =>
      (value.required_pull_request_reviews.dismiss_stale_reviews = false),
  ],
  ["force push", (value) => (value.allow_force_pushes.enabled = true)],
]) {
  test(`rejects ${name}`, () => {
    const value = fixture();
    mutate(value);
    assert.throws(() => verifyDefaultBranchControls(value));
  });
}
