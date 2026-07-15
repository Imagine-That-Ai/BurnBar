import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  parseDomainCoreBuildProfileResolverArgs,
  resolveDomainCoreCandidateIdentity,
  validateDomainCoreCandidateIdentity,
} from "./domain-core-candidate-receipt.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

test("profile resolver arguments reject ambiguity", () => {
  assert.equal(
    parseDomainCoreBuildProfileResolverArgs([
      "--profile",
      "internal",
      "--format",
      "json",
    ]).get("--profile"),
    "internal",
  );
  for (const argv of [
    [],
    ["--profile", "internal", "--profile", "beta"],
    ["--profile", "internal", "--unknown", "value"],
    ["--profile", "--format", "json"],
  ]) {
    assert.throws(() => parseDomainCoreBuildProfileResolverArgs(argv));
  }
});

function git(root, ...args) {
  return execFileSync("git", ["-C", root, ...args], {
    encoding: "utf8",
  }).trim();
}

function repository() {
  const root = mkdtempSync(join(tmpdir(), "domain-core-candidate-"));
  mkdirSync(join(root, "crates/openburnbar-domain-core"), { recursive: true });
  writeFileSync(
    join(root, "crates/openburnbar-domain-core/union-abi-manifest.json"),
    `${JSON.stringify({ coreVersion: "1.2.3", abiVersion: 7, sourceSha256: "c".repeat(64) })}\n`,
  );
  git(root, "init", "--quiet");
  git(root, "config", "user.email", "domain-core-test@example.invalid");
  git(root, "config", "user.name", "Domain Core Test");
  git(root, "add", ".");
  git(root, "commit", "--quiet", "-m", "fixture");
  return root;
}

test("candidate receipt binds the clean checkout commit to the artifact identity", (context) => {
  const root = repository();
  context.after(() => rmSync(root, { recursive: true, force: true }));
  const commit = git(root, "rev-parse", "HEAD");
  assert.deepEqual(
    resolveDomainCoreCandidateIdentity({
      repoRoot: root,
      expectedCandidateCommit: commit,
      verifyArtifactIdentity: false,
    }),
    {
      candidateCommit: commit,
      coreVersion: "1.2.3",
      abiVersion: 7,
      sourceSha256: "c".repeat(64),
    },
  );
});

test("candidate receipt rejects dirty or differently checked out source", (context) => {
  const root = repository();
  context.after(() => rmSync(root, { recursive: true, force: true }));
  assert.throws(
    () =>
      resolveDomainCoreCandidateIdentity({
        repoRoot: root,
        expectedCandidateCommit: "d".repeat(40),
        verifyArtifactIdentity: false,
      }),
    /candidate commit mismatch/,
  );
  writeFileSync(join(root, "untracked.txt"), "dirty\n");
  assert.throws(
    () =>
      resolveDomainCoreCandidateIdentity({
        repoRoot: root,
        verifyArtifactIdentity: false,
      }),
    /checkout must be clean/,
  );
});

test("trusted union gate evaluates candidate data without executing candidate code", (context) => {
  const root = repository();
  const tools = mkdtempSync(join(tmpdir(), "domain-core-trusted-gate-"));
  const marker = join(root, "candidate-gate-executed");
  const maliciousGate = join(root, "scripts/ci/domain-core-union-gate.py");
  const trustedGate = join(tools, "domain-core-union-gate.py");
  mkdirSync(dirname(maliciousGate), { recursive: true });
  writeFileSync(maliciousGate, `from pathlib import Path\nPath(${JSON.stringify(marker)}).write_text("executed")\nprint("${"c".repeat(64)}")\n`);
  git(root, "add", ".");
  git(root, "commit", "--quiet", "-m", "candidate gate");
  writeFileSync(trustedGate, `print("${"c".repeat(64)}")\n`);
  context.after(() => {
    rmSync(root, { recursive: true, force: true });
    rmSync(tools, { recursive: true, force: true });
  });

  const identity = resolveDomainCoreCandidateIdentity({
    repoRoot: root,
    unionGatePath: trustedGate,
  });
  assert.equal(identity.sourceSha256, "c".repeat(64));
  assert.equal(existsSync(marker), false);
});

test("repository candidate identity is verified by the canonical Rust union gate", () => {
  const identity = resolveDomainCoreCandidateIdentity({
    repoRoot,
    requireClean: false,
  });
  assert.match(identity.candidateCommit, /^[0-9a-f]{40}$/);
  assert.equal(identity.coreVersion, "0.1.0");
  assert.equal(identity.abiVersion, 3);
  assert.match(identity.sourceSha256, /^[0-9a-f]{64}$/);
});

test("candidate identity is exact and canonical", () => {
  const valid = {
    candidateCommit: "a".repeat(40),
    coreVersion: "1.2.3-rc.1+build.4",
    abiVersion: 1,
    sourceSha256: "b".repeat(64),
  };
  assert.deepEqual(validateDomainCoreCandidateIdentity(valid), valid);
  for (const invalid of [
    { ...valid, sourceSha256: "B".repeat(64) },
    { ...valid, abiVersion: 0 },
    { ...valid, abiVersion: 1.5 },
    { ...valid, coreVersion: "v1.2.3" },
    { ...valid, coreVersion: "1.2.3-01" },
    { ...valid, candidateCommit: "A".repeat(40) },
  ]) {
    assert.throws(() => validateDomainCoreCandidateIdentity(invalid));
  }
});
