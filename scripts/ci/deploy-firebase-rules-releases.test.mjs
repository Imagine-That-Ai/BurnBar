#!/usr/bin/env node
import assert from "node:assert/strict";

import {
  buildReleaseCreateRequest,
  buildReleasePatchRequest,
  buildReleaseUpdate,
} from "./deploy-firebase-rules-releases.mjs";

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
});
assert.equal(
  Object.hasOwn(JSON.parse(patch.body), "updateMask"),
  false,
  "Firebase Rules release PATCH must not send an unsupported update mask",
);

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

console.log("PASS: Firebase Rules release request builders");
