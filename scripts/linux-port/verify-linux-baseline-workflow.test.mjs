import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { repoRoot } from "./lib/linux-release-common.mjs";
import {
  BASELINE_WORKFLOW_PATH,
  verifyLinuxBaselineWorkflowText,
} from "./verify-linux-baseline-workflow.mjs";

const canonical = fs.readFileSync(
  path.join(repoRoot, BASELINE_WORKFLOW_PATH),
  "utf8",
);

test("protected lifecycle baseline workflow passes its exact contract", () => {
  assert.deepEqual(verifyLinuxBaselineWorkflowText(canonical), []);
});

for (const [name, mutation] of [
  [
    "stable latest publication",
    (body) => body.replace("--latest=false", "--latest=true"),
  ],
  [
    "update-feed publication",
    (body) =>
      body.replace(
        "Verify public baseline is lifecycle-compatible",
        "upload-linux-downloads-r2.sh\n      - name: Verify public baseline is lifecycle-compatible",
      ),
  ],
  [
    "parity-shaped promotion closure",
    (body) => body.replace("package-closure.json", "promotion-closure.json"),
  ],
  [
    "unverified candidate",
    (body) => body.replace("            --candidate \\\n", ""),
  ],
  [
    "mutable branch tag",
    (body) => body.replace('          test "$tag_commit" = "$GITHUB_SHA"\n', ""),
  ],
  [
    "second baseline allowed",
    (body) =>
      body.replace(
        "      - name: Refuse a second lifecycle bootstrap",
        "      - name: Ignore an existing lifecycle baseline",
      ),
  ],
  [
    "release before verification",
    (body) => {
      const publish = body.indexOf(
        "      - name: Publish non-latest prerelease baseline",
      );
      const verify = body.indexOf(
        "      - name: Verify candidate signatures, provenance, and package identity",
      );
      const next = body.indexOf("\n      - name:", publish + 1);
      const block = body.slice(publish, next);
      return `${body.slice(0, verify)}${block}\n${body.slice(verify, publish)}${body.slice(next + 1)}`;
    },
  ],
  [
    "broad attestation permission",
    (body) =>
      body.replace(
        "  contents: write\n",
        "  contents: write\n  attestations: write\n",
      ),
  ],
]) {
  test(`baseline contract rejects ${name}`, () => {
    assert.notDeepEqual(verifyLinuxBaselineWorkflowText(mutation(canonical)), []);
  });
}
