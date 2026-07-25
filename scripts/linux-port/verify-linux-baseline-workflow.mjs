#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const BASELINE_WORKFLOW_PATH =
  ".github/workflows/linux-release-baseline.yml";

const REQUIRED = Object.freeze([
  "name: Linux Lifecycle Baseline Bootstrap",
  "workflow_dispatch:",
  "candidate_run_id:",
  "permissions:\n  actions: read\n  contents: write",
  "environment: release",
  "ref: ${{ github.sha }}",
  "resolve-product-evidence-run.mjs",
  '--run-id "$CANDIDATE_RUN_ID"',
  '--target-head "$TARGET_HEAD"',
  "Refuse a second lifecycle bootstrap",
  "resolve-linux-previous-release.mjs",
  "Require an exact pre-existing Linux tag",
  'tag="linux-v${version}"',
  'test "$tag_commit" = "$GITHUB_SHA"',
  "Download the exact candidate",
  "artifact-ids: ${{ steps.candidate.outputs.artifact_id }}",
  "run-id: ${{ inputs.candidate_run_id }}",
  "Verify candidate signatures, provenance, and package identity",
  "verify-linux-release.mjs",
  "--candidate",
  "--phase final",
  "Materialize format-specific lifecycle release assets",
  "materialize-linux-lifecycle-release-assets.mjs",
  "Stage the exact non-promotable lifecycle assets",
  "OpenBurnBar_${version}_${native_arch}.deb",
  "openburnbar-${version}-*-${architecture}.pkg.tar.zst",
  "openburnbar-${version}-${format}-${architecture}.installed-manifest.json",
  "openburnbar-${version}-${format}-${architecture}.installed-manifest.ed25519",
  "product-proof-closure.json.ed25519.sig",
  "Publish non-latest prerelease baseline",
  "gh release create",
  "--prerelease",
  "--verify-tag",
  '--target "$GITHUB_SHA"',
  "--latest=false",
  "does not claim macOS parity",
  "does not publish the Linux update feed",
  "Verify public baseline is lifecycle-compatible",
  "--previous-version",
  "linux-lifecycle-baseline-${{ github.sha }}",
]);

const FORBIDDEN = Object.freeze([
  "push:",
  "schedule:",
  "id-token: write",
  "attestations: write",
  "artifact-metadata: write",
  "linux-release-promote.yml",
  "resolve-product-receipt-artifacts.mjs",
  "Download all 280 exact receipt artifacts",
  "attest-product-requirement.mjs",
  "validate-parity-ledger.mjs",
  "finalize-linux-promotion-closure.mjs",
  "promotion-closure.json",
  "latest-linux.json",
  "upload-linux-downloads-r2.sh",
  "downloads.burnbar.ai",
  "--latest=true",
  "--draft",
  "gh release edit",
]);

export function verifyLinuxBaselineWorkflowText(body) {
  const failures = [];
  if (typeof body !== "string" || body.length === 0) {
    return ["baseline workflow is missing or empty"];
  }
  for (const marker of REQUIRED) {
    if (!body.includes(marker)) {
      failures.push(`baseline workflow is missing required marker: ${marker}`);
    }
  }
  for (const marker of FORBIDDEN) {
    if (body.includes(marker)) {
      failures.push(`baseline workflow contains forbidden marker: ${marker}`);
    }
  }
  if (!/^\s+--candidate\s+\\$/mu.test(body)) {
    failures.push(
      "baseline workflow must verify the downloaded artifact as a candidate",
    );
  }
  const releaseCreates = body.match(/\bgh release create\b/gu) ?? [];
  if (releaseCreates.length !== 1) {
    failures.push(
      `baseline workflow must create exactly one release, found ${releaseCreates.length}`,
    );
  }
  const jobs = body.match(/^  [a-z0-9-]+:\n/gmu) ?? [];
  if (jobs.length !== 1 || !body.includes("  publish-baseline:\n")) {
    failures.push("baseline workflow must contain only publish-baseline");
  }
  const permissionBlock =
    body.match(/^permissions:\n(?<block>(?:  .+\n)+)/mu)?.groups?.block ?? "";
  if (permissionBlock !== "  actions: read\n  contents: write\n") {
    failures.push("baseline workflow permissions are not exact");
  }
  const checkoutIndex = body.indexOf("Check out the exact baseline source");
  const resolverIndex = body.indexOf(
    "Resolve the immutable successful candidate artifact",
  );
  const refusalIndex = body.indexOf("Refuse a second lifecycle bootstrap");
  const downloadIndex = body.indexOf("Download the exact candidate");
  const verifyIndex = body.indexOf(
    "Verify candidate signatures, provenance, and package identity",
  );
  const publishIndex = body.indexOf("Publish non-latest prerelease baseline");
  const readbackIndex = body.indexOf(
    "Verify public baseline is lifecycle-compatible",
  );
  if (
    ![
      checkoutIndex,
      resolverIndex,
      refusalIndex,
      downloadIndex,
      verifyIndex,
      publishIndex,
      readbackIndex,
    ].every((index) => index >= 0) ||
    !(
      checkoutIndex < resolverIndex &&
      resolverIndex < refusalIndex &&
      refusalIndex < downloadIndex &&
      downloadIndex < verifyIndex &&
      verifyIndex < publishIndex &&
      publishIndex < readbackIndex
    )
  ) {
    failures.push("baseline workflow security steps are out of order");
  }
  return failures;
}

export function verifyLinuxBaselineWorkflow(
  repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../.."),
) {
  const workflow = path.join(repoRoot, BASELINE_WORKFLOW_PATH);
  const body = fs.existsSync(workflow) ? fs.readFileSync(workflow, "utf8") : "";
  return verifyLinuxBaselineWorkflowText(body);
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const failures = verifyLinuxBaselineWorkflow();
  process.stdout.write(
    `${JSON.stringify({ passed: failures.length === 0, failures }, null, 2)}\n`,
  );
  process.exitCode = failures.length === 0 ? 0 : 1;
}
