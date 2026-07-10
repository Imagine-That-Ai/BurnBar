#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { verifyLinuxAttestationFacadeCi } from "./verify-linux-attestation-facade-ci.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

function valid() {
  return {
    workflow: readFileSync(join(ROOT, ".github/workflows/fast-feedback.yml"), "utf8"),
    dependabot: readFileSync(join(ROOT, ".github/dependabot.yml"), "utf8"),
    audit: readFileSync(join(ROOT, "scripts/ci/check-npm-audit-fail-closed.mjs"), "utf8"),
  };
}

function mutate(input, field, before, after = "") {
  const updated = input[field].replace(before, after);
  assert.notEqual(updated, input[field], `mutation did not change ${field}`);
  input[field] = updated;
  return input;
}

test("current Linux attestation facade CI contract passes", () => {
  assert.deepEqual(verifyLinuxAttestationFacadeCi(valid()), {
    passed: true,
    failures: [],
  });
});

test("removing facade path detection fails", () => {
  const input = mutate(
    valid(),
    "workflow",
    "services/linux-attestation-facade/",
  );
  assert.equal(verifyLinuxAttestationFacadeCi(input).passed, false);
});

test("removing either shared broker contract trigger fails", () => {
  for (const trigger of [
    "tests/fixtures/linux-attestation/broker-v2-golden\\.json",
    "schemas/linux-attestation-evidence-bundle-header-v1\\.schema\\.json",
  ]) {
    const input = mutate(valid(), "workflow", trigger);
    assert.equal(verifyLinuxAttestationFacadeCi(input).passed, false, trigger);
  }
});

test("removing facade from the required aggregate fails", () => {
  const input = mutate(
    valid(),
    "workflow",
    "      - linux-attestation-facade-fast\n",
  );
  assert.equal(verifyLinuxAttestationFacadeCi(input).passed, false);
});

test("aggregate keeps unrelated PRs green when the facade job is skipped", () => {
  const withoutAlways = mutate(
    valid(),
    "workflow",
    /(  fast-feedback-gate:[\s\S]*?\n    if: )always\(\)/u,
    "$1success()",
  );
  assert.equal(verifyLinuxAttestationFacadeCi(withoutAlways).passed, false);

  const rejectingSkipped = mutate(
    valid(),
    "workflow",
    "not in ('success', 'skipped')",
    "not in ('success')",
  );
  const result = verifyLinuxAttestationFacadeCi(rejectingSkipped);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /unrelated PRs/u.test(failure)));
});

test("suppressing facade audit failure fails", () => {
  const input = mutate(
    valid(),
    "workflow",
    "npm audit --prefix services/linux-attestation-facade --audit-level=high",
    "npm audit --prefix services/linux-attestation-facade --audit-level=high || true",
  );
  const result = verifyLinuxAttestationFacadeCi(input);
  assert.equal(result.passed, false);
  assert.ok(result.failures.some((failure) => /suppress/u.test(failure)));
});

test("removing either immutable Docker target build fails", () => {
  for (const target of ["ingress", "verifier"]) {
    const input = mutate(
      valid(),
      "workflow",
      new RegExp(`^      - name: Build ${target} image\\n        run: .*\\n`, "mu"),
    );
    assert.equal(verifyLinuxAttestationFacadeCi(input).passed, false, target);
  }
});

test("removing the facade Dependabot entry fails", () => {
  const input = mutate(
    valid(),
    "dependabot",
    /\n  - package-ecosystem: "npm"\n    directory: "\/services\/linux-attestation-facade"[\s\S]*?(?=\n  - package-ecosystem:)/u,
  );
  assert.equal(verifyLinuxAttestationFacadeCi(input).passed, false);
});

test("removing the facade from the repository audit meta-gate fails", () => {
  const input = mutate(
    valid(),
    "audit",
    '  "services/linux-attestation-facade",\n',
  );
  assert.equal(verifyLinuxAttestationFacadeCi(input).passed, false);
});
