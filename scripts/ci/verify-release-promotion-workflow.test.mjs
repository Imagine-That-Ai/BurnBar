import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(
  new URL("../../.github/workflows/release.yml", import.meta.url),
  "utf8",
);

function workflowJobs(source) {
  const jobsStart = source.indexOf("\njobs:\n");
  assert.notEqual(jobsStart, -1, "release workflow must define jobs");
  const jobs = source.slice(jobsStart + "\njobs:\n".length);
  const headings = [...jobs.matchAll(/^  ([A-Za-z0-9_-]+):\n/gmu)];
  return new Map(
    headings.map((heading, index) => {
      const start = heading.index;
      const end = headings[index + 1]?.index ?? jobs.length;
      return [heading[1], jobs.slice(start, end)];
    }),
  );
}

const jobs = workflowJobs(workflow);

function job(name) {
  const block = jobs.get(name);
  assert.ok(block, `release workflow must define ${name}`);
  return block;
}

test("promote=true selects the dedicated promotion root and skips every build root", () => {
  const rootJobs = [...jobs]
    .filter(([, block]) => !/^    needs:/mu.test(block))
    .map(([name]) => name);
  assert.deepEqual(rootJobs, [
    "release-promotion",
    "release-functions-gate",
    "release-extension-gate",
    "release-supply-chain-gate",
    "release-preflight",
  ]);

  assert.match(
    job("release-promotion"),
    /^    if: github\.event_name == 'workflow_dispatch' && inputs\.promote$/mu,
  );
  const buildRootGuard =
    /^    if: \(startsWith\(github\.ref, 'refs\/tags\/v'\) \|\| github\.event_name == 'workflow_dispatch'\) && !\(github\.event_name == 'workflow_dispatch' && inputs\.promote\)$/mu;
  for (const name of rootJobs.slice(1)) {
    assert.match(
      job(name),
      buildRootGuard,
      `${name} must be disabled for promote=true`,
    );
  }
});

test("normal publication is permanently non-promoting", () => {
  const publication = job("domain-core-native-release-evidence");
  assert.match(publication, /^\s+PROMOTE: "false"$/mu);
  assert.match(publication, /--promote "\$PROMOTE"/u);
  assert.doesNotMatch(publication, /PROMOTE:.*inputs\.promote/u);
  assert.equal(
    [...workflow.matchAll(/^\s+PROMOTE: "false"$/gmu)].length,
    1,
    "release workflow must have one explicit non-promoting publication input",
  );
});

test("remote audit and every public-trust check precede the sole promotion command", () => {
  const promotion = job("release-promotion");
  const orderedMarkers = [
    "promote-github-release.mjs audit",
    "verify-release-attestations.sh",
    "cosign verify-blob-attestation",
    "verify-apple-appcheck-release-artifact.sh",
    "verify-public-macos-download-trust.sh",
    "promote-github-release.mjs promote",
  ];
  let previous = -1;
  for (const marker of orderedMarkers) {
    const current = promotion.indexOf(marker);
    assert.ok(current > previous, `${marker} must appear in audited order`);
    previous = current;
  }
  assert.equal(
    [...workflow.matchAll(/promote-github-release\.mjs promote/gmu)].length,
    1,
    "release workflow must expose exactly one promotion command",
  );
});

test("live feed verification follows the exact successful promotion", () => {
  const verification = job("verify-live-update-feed");
  assert.match(verification, /^    needs: \[release-promotion\]$/mu);
  assert.match(
    verification,
    /^    if: \$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.promote == true && needs\.release-promotion\.result == 'success' \}\}$/mu,
  );
  assert.match(verification, /^          ref: \$\{\{ inputs\.tag \}\}$/mu);
});

test("workflow YAML contains no direct GitHub release mutation", () => {
  assert.doesNotMatch(
    workflow,
    /\bgh\s+release\s+(?:create|delete|edit|upload)\b/u,
  );
  assert.doesNotMatch(
    workflow,
    /\bgh\s+api\b[^\n]*(?:--method|-X)\s+(?:DELETE|PATCH|POST|PUT)\b/u,
  );
});
