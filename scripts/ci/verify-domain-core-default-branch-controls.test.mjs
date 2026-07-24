import assert from "node:assert/strict";
import test from "node:test";

import {
  verifyDefaultBranchControls,
  verifyMergeQueueRulesets,
  verifyUmbrellaInventory,
} from "./verify-domain-core-default-branch-controls.mjs";

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

function umbrellaFixture() {
  return {
    context: "BurnBar CI Gate",
    required_contexts: [
      "Android PR Gate",
      "Domain Core PR Gate",
      "Domain Core Trusted Deletion Guard",
      "PR Native Gate",
      "PR Windows Full Gate",
      "PR Windows Gate",
    ],
  };
}

function rulesetFixture() {
  return [
    {
      id: 19396995,
      target: "branch",
      enforcement: "active",
      bypass_actors: [],
      conditions: {
        ref_name: {
          include: ["refs/heads/main"],
          exclude: [],
        },
      },
      rules: [
        {
          type: "merge_queue",
          parameters: { grouping_strategy: "ALLGREEN" },
        },
      ],
    },
  ];
}

test("accepts fail-closed official main protection", () => {
  assert.equal(verifyDefaultBranchControls(fixture()).branch, "main");
});

test("accepts trusted umbrella inventory and current-base merge queue", () => {
  assert.equal(
    verifyUmbrellaInventory(umbrellaFixture()).umbrellaRequiredContexts.length,
    6,
  );
  assert.equal(
    verifyMergeQueueRulesets(rulesetFixture()).mergeQueueRuleset,
    19396995,
  );
});

test("rejects an umbrella missing any direct safety component", () => {
  const value = umbrellaFixture();
  value.required_contexts.pop();
  assert.throws(() => verifyUmbrellaInventory(value), /PR Windows Gate/);
});

for (const [name, mutate] of [
  [
    "merge queue bypass actors",
    (value) => value[0].bypass_actors.push({ actor_type: "RepositoryRole" }),
  ],
  [
    "non-ALLGREEN merge queue",
    (value) =>
      (value[0].rules[0].parameters.grouping_strategy = "HEADGREEN"),
  ],
  [
    "merge queue that does not protect main",
    (value) =>
      (value[0].conditions.ref_name.include = ["refs/heads/develop"]),
  ],
]) {
  test(`rejects ${name}`, () => {
    const value = rulesetFixture();
    mutate(value);
    assert.throws(() => verifyMergeQueueRulesets(value));
  });
}

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
