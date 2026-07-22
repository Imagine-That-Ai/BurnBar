// Static workflow contract test for the single canonical Windows release
// bundle in .github/workflows/openburnbar-release-windows.yml.
//
// Defends the contract fixed by the PR #1820 exact-head review defect: the
// canonical OpenBurnBar-${VERSION}-windows-release.zip must be built by the
// deterministic create-windows-domain-core-release-bundle.py bundler AFTER
// the updater-metadata generation (Sign the update feed) produces the three
// metadata files, must contain the four app packages plus those three
// metadata files, and the release-evidence job must attest that exact bundle
// via actions/attest@. No earlier incomplete 7z-based bundle authority may
// remain in the build-sign job.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

const workflow = readFileSync(
  new URL(
    "../../.github/workflows/openburnbar-release-windows.yml",
    import.meta.url,
  ),
  "utf8",
);

// Slice the body of a top-level job from the workflow source. `name` is the
// job key; `nextName` bounds the slice (omitted => through end of file).
// Mirrors the helper used by verify-domain-core-native-release-workflows.test.mjs
// so the assertion style stays consistent with the sibling contract suite.
function job(source, name, nextName) {
  const start = source.indexOf(`\n  ${name}:`);
  assert.notEqual(start, -1, `missing ${name}`);
  const end = nextName ? source.indexOf(`\n  ${nextName}:`, start + 1) : -1;
  return source.slice(start, end === -1 ? source.length : end);
}

// Extract the body of a `- name:` step from a job slice, from its name line
// up to (but not including) the next `- name:` line at the same indent, or
// the end of the slice if it is the last step.
function step(jobSlice, stepName) {
  const anchor = `\n      - name: ${stepName}`;
  const start = jobSlice.indexOf(anchor);
  if (start === -1) {
    return null;
  }
  const nextStep = jobSlice.indexOf("\n      - name:", start + anchor.length);
  return nextStep === -1
    ? jobSlice.slice(start)
    : jobSlice.slice(start, nextStep);
}

// Index of a step name within a job slice, used for ordering assertions.
function stepIndex(jobSlice, stepName) {
  return jobSlice.indexOf(`      - name: ${stepName}`);
}

const buildSign = job(workflow, "build-sign", "supply-chain");
const evidence = job(workflow, "domain-core-windows-release-evidence");

const METADATA_FILES = [
  "windows-update-feed-v${VERSION}.json",
  "appcast-windows.xml",
  "latest-windows.json",
];
const APP_PACKAGES = [
  "OpenBurnBar-${VERSION}-win-x64.zip",
  "OpenBurnBar-${VERSION}-win-arm64.zip",
  "OpenBurnBar-${VERSION}-x64.msix",
  "OpenBurnBar-${VERSION}-arm64.msix",
];

test("build-sign has no incomplete 7z canonical bundle authority", () => {
  // The pre-fix defect packaged OpenBurnBar-${VERSION}-windows-release.zip
  // with a bare `7z a -tzip` invocation over only the four app packages,
  // before any updater metadata existed. That step is an incomplete bundle
  // authority — a bundle claiming the canonical name while missing the
  // three metadata files the deterministic bundler requires. It must not
  // survive the fix: no 7z step may write the canonical release zip.
  assert.doesNotMatch(
    buildSign,
    /7z a -tzip[^\n]*\$\{?VERSION\}?-windows-release\.zip/u,
    "the canonical Windows release zip must not be built by a bare 7z archive step",
  );
  assert.equal(
    stepIndex(buildSign, "Package canonical cross-architecture Windows release bundle"),
    -1,
    "the pre-fix incomplete 'Package canonical cross-architecture' step must be removed",
  );
});

test("build-sign builds the canonical bundle with the deterministic bundler after updater metadata", () => {
  const feedIdx = stepIndex(buildSign, "Sign the update feed (pinned Ed25519, independent of Authenticode)");
  const bundleIdx = stepIndex(buildSign, "Build deterministic canonical Windows release bundle");
  assert.notEqual(feedIdx, -1, "Sign the update feed step must exist");
  assert.notEqual(bundleIdx, -1, "Build deterministic canonical Windows release bundle step must exist");
  // Ordering contract: the canonical bundle must be created AFTER the update
  // feed step generates the three metadata files. Pre-fix, a bundle step ran
  // before the feed; this pins the correct order.
  assert.ok(
    bundleIdx > feedIdx,
    "canonical bundle step must run after the update feed signing step",
  );

  const bundleStep = step(buildSign, "Build deterministic canonical Windows release bundle");
  assert.ok(bundleStep, "bundle step body must be present");
  // Single canonical authority: the deterministic python bundler.
  assert.match(
    bundleStep,
    /create-windows-domain-core-release-bundle\.py/u,
    "canonical bundle must be built by create-windows-domain-core-release-bundle.py",
  );
  assert.match(
    bundleStep,
    /--output[^\n]*OpenBurnBar-\$\{VERSION\}-windows-release\.zip/u,
    "bundler must write the canonical OpenBurnBar-${VERSION}-windows-release.zip",
  );
});

test("build-sign stages all four app packages and three metadata files into the canonical bundle input", () => {
  const bundleStep = step(buildSign, "Build deterministic canonical Windows release bundle");
  assert.ok(bundleStep, "bundle step body must be present");
  // The bundler input must contain the four app packages AND the three
  // updater-metadata files. Pre-fix, only the four app packages were zipped
  // and the metadata did not yet exist. Each member is asserted by name so a
  // dropped file redds the test.
  for (const pkg of APP_PACKAGES) {
    assert.ok(
      bundleStep.includes(pkg),
      `canonical bundle input must include app package ${pkg}`,
    );
  }
  for (const meta of METADATA_FILES) {
    assert.ok(
      bundleStep.includes(meta),
      `canonical bundle input must include metadata file ${meta}`,
    );
  }
});

test("evidence job rebuilds the canonical bundle with the deterministic bundler and attests that exact bundle", () => {
  const bundleStep = step(evidence, "Build deterministic x64 and ARM64 canonical release bundle");
  assert.ok(bundleStep, "evidence bundle step body must be present");
  assert.match(
    bundleStep,
    /create-windows-domain-core-release-bundle\.py/u,
    "evidence job must build the canonical bundle with create-windows-domain-core-release-bundle.py",
  );
  // The evidence job assigns the canonical artifact path to a shell variable
  // and passes it to --output; assert the canonical filename is targeted.
  assert.match(
    bundleStep,
    /artifact="\$RUNNER_TEMP\/OpenBurnBar-\$\{VERSION\}-windows-release\.zip"/u,
    "evidence job must target the canonical OpenBurnBar-${VERSION}-windows-release.zip",
  );
  // The evidence plan consumes the exact bundle artifact id from the bundle
  // step, not an earlier incomplete authority.
  assert.match(
    evidence,
    /--artifact "\$\{\{ steps\.bundle\.outputs\.artifact \}\}"/u,
    "evidence plan must consume steps.bundle.outputs.artifact",
  );
});

test("evidence job attests the exact canonical bundle via actions/attest@", () => {
  // Both Windows v2 predicate attestations must name the exact bundle as
  // their subject. Pre-fix, the evidence plan attested an earlier incomplete
  // bundle; post-fix it must attest the deterministic bundle step output.
  const quota = step(evidence, "Attest Windows quota predicate");
  const cloudVault = step(evidence, "Attest Windows CloudVault predicate");
  assert.ok(quota, "quota attestation step must exist");
  assert.ok(cloudVault, "CloudVault attestation step must exist");
  for (const attestStep of [quota, cloudVault]) {
    assert.match(
      attestStep,
      /uses: actions\/attest@[0-9a-f]{40}/u,
      "attestation must use pinned actions/attest@",
    );
    assert.match(
      attestStep,
      /subject-path: \$\{\{ steps\.bundle\.outputs\.artifact \}\}/u,
      "attestation subject-path must be the exact canonical bundle artifact",
    );
    assert.match(
      attestStep,
      /predicate-type: https:\/\/openburnbar\.dev\/attestations\/domain-core-release-artifact\/v2/u,
      "attestation must use the v2 Windows release predicate type",
    );
  }
});

test("the workflow retains a single canonical Windows release bundle authority", () => {
  // No bare 7z archive may write the canonical bundle name anywhere in the
  // workflow; only the deterministic python bundler is the authority. This
  // catches a reintroduced incomplete bundle in any job, not just build-sign.
  assert.doesNotMatch(
    workflow,
    /7z a -tzip[^\n]*\$\{?VERSION\}?-windows-release\.zip/u,
    "no 7z step anywhere may build the canonical Windows release zip",
  );
  // Count actual python3 invocations of the bundler (excluding comment
  // references). One algorithm, run twice: build-sign creates + uploads,
  // the evidence job independently rebuilds + attests.
  const bundlerCalls =
    workflow.match(/python3 scripts\/ci\/create-windows-domain-core-release-bundle\.py/gu) ?? [];
  assert.equal(
    bundlerCalls.length,
    2,
    "the deterministic bundler must be invoked exactly twice (build-sign create + evidence verify/attest)",
  );
});