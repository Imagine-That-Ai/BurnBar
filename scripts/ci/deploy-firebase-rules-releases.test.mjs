#!/usr/bin/env node
import assert from "node:assert/strict";

import {
  buildReleaseCreateRequest,
  buildReleasePatchRequest,
  buildReleaseUpdate,
  isRetryableFirebaseRulesApiError,
  releasesNeedingRulesetDeploy,
  rulesetFileContentHash,
} from "./deploy-firebase-rules-releases.mjs";
import {
  compactFirebaseRulesSource,
  rulesSourceForDeploy,
} from "./firebase-rules-source.mjs";

const releaseName = "projects/demo-project/releases/cloud.firestore";
const rulesetName = "projects/demo-project/rulesets/example-ruleset";

const update = buildReleaseUpdate(releaseName, rulesetName);
assert.deepEqual(update, {
  name: releaseName,
  rulesetName,
});

const patch = buildReleasePatchRequest(releaseName, rulesetName);
assert.equal(patch.method, "PATCH");
assert.deepEqual(JSON.parse(patch.body), {
  release: {
    name: releaseName,
    rulesetName,
  },
  updateMask: "rulesetName",
});

const create = buildReleaseCreateRequest(releaseName, rulesetName);
assert.equal(create.method, "POST");
assert.deepEqual(JSON.parse(create.body), {
  name: releaseName,
  rulesetName,
});

assert.throws(
  () => buildReleasePatchRequest("demo-project/releases/cloud.firestore", rulesetName),
  /releaseName must be a Firebase resource name/,
);
assert.throws(
  () => buildReleasePatchRequest(releaseName, "projects/demo-project/releases/not-a-ruleset"),
  /rulesetName must be a Firebase resource name/,
);
assert.equal(
  isRetryableFirebaseRulesApiError(
    new TypeError("fetch failed", {
      cause: Object.assign(new Error("Connect Timeout Error"), {
        code: "UND_ERR_CONNECT_TIMEOUT",
      }),
    }),
  ),
  true,
);
const invalidRules = new Error("invalid argument");
invalidRules.status = 400;
assert.equal(isRetryableFirebaseRulesApiError(invalidRules), false);

const verboseFirestoreRules = [
  "rules_version = '2'; // keep the version statement",
  "service cloud.firestore {",
  "  match /databases/{database}/documents {",
  "    // URLs inside strings are not comments.",
  "    function validRelay(value) {",
  "      return value.matches(\"^wss://relay.example.test/path$\"); // trailing note",
  "    }",
  "  }",
  "}",
  "",
].join("\n");
assert.equal(
  compactFirebaseRulesSource(verboseFirestoreRules),
  [
    "rules_version = '2';",
    "service cloud.firestore {",
    "match /databases/{database}/documents {",
    "function validRelay(value) {",
    "return value.matches(\"^wss://relay.example.test/path$\");",
    "}",
    "}",
    "}",
    "",
  ].join("\n"),
);
assert.equal(
  rulesSourceForDeploy("firestore.rules", verboseFirestoreRules),
  compactFirebaseRulesSource(verboseFirestoreRules),
);
assert.equal(
  rulesSourceForDeploy("storage.rules", verboseFirestoreRules),
  verboseFirestoreRules,
);

const desiredRuleset = {
  source: {
    files: [
      {
        name: "firestore.rules",
        content: [
          "rules_version = '2';",
          "service cloud.firestore {",
          "  match /databases/{database}/documents {",
          "    match /{document=**} { allow read: if true; }",
          "  }",
          "}",
          "",
        ].join("\n"),
      },
    ],
  },
};
const desiredContentHash = rulesetFileContentHash(
  desiredRuleset,
  "firestore.rules",
);
assert.equal(
  rulesetFileContentHash(
    {
      source: {
        files: [
          {
            name: "firestore.rules",
            content: `${desiredRuleset.source.files[0].content}\n\n`,
          },
        ],
      },
    },
    "firestore.rules",
  ),
  desiredContentHash,
);
assert.equal(rulesetFileContentHash(desiredRuleset, "storage.rules"), null);

const missing = new Error("not found");
missing.status = 404;
const calls = new Map();
const count = (name) => calls.set(name, (calls.get(name) || 0) + 1);
const unchangedRulesetName = "projects/demo-project/rulesets/current";
const staleRulesetName = "projects/demo-project/rulesets/stale";
const releases = [
  "projects/demo-project/releases/cloud.firestore",
  "projects/demo-project/releases/firebase.storage/demo.appspot.com",
  "projects/demo-project/releases/firebase.storage/stale.appspot.com",
  "projects/demo-project/releases/firebase.storage/missing.appspot.com",
];
const deployPlan = await releasesNeedingRulesetDeploy({
  releaseNames: releases,
  desiredContentHash,
  fileName: "firestore.rules",
  async fetchResource(name) {
    count(name);
    if (name === releases[0] || name === releases[1]) {
      return { rulesetName: unchangedRulesetName };
    }
    if (name === releases[2]) return { rulesetName: staleRulesetName };
    if (name === releases[3]) throw missing;
    if (name === unchangedRulesetName) return desiredRuleset;
    if (name === staleRulesetName) {
      return {
        source: {
          files: [
            { name: "firestore.rules", content: "rules_version = '2';\n" },
          ],
        },
      };
    }
    throw new Error(`unexpected test resource: ${name}`);
  },
});
assert.deepEqual(deployPlan, {
  staleReleaseNames: [releases[2], releases[3]],
  unchangedReleaseCount: 2,
});
assert.equal(
  calls.get(unchangedRulesetName),
  1,
  "shared current ruleset should only be fetched once",
);

console.log("PASS: Firebase Rules release request builders");
