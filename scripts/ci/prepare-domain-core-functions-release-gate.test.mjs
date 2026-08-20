import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { prepareInactiveFunctionsReleaseGate } from "./prepare-domain-core-functions-release-gate.mjs";

const RELEASE = "a".repeat(40);
const HISTORICAL = "b".repeat(40);
const IDENTITY = {
  candidateCommit: RELEASE,
  coreVersion: "0.1.0",
  abiVersion: 3,
  sourceSha256: "c".repeat(64),
};

test("binds inactive Functions releases directly to C=P=R without signer artifacts", () => {
  const directory = mkdtempSync(join(tmpdir(), "inactive-functions-gate-"));
  const profile = join(directory, "profile.json");
  const output = join(directory, "gate.json");
  writeFileSync(
    profile,
    `${JSON.stringify({ candidateIdentity: IDENTITY })}\n`,
  );
  try {
    const gate = prepareInactiveFunctionsReleaseGate({
      releaseCommit: RELEASE,
      releaseTag: "v1.0.40+repair.2",
      profilePath: profile,
      outputPath: output,
      activationResolver: () => ({
        active: false,
        candidateCommit: HISTORICAL,
        activationCommit: HISTORICAL,
        coreVersion: IDENTITY.coreVersion,
        abiVersion: IDENTITY.abiVersion,
        sourceSha256: IDENTITY.sourceSha256,
        changedPathsSha256: "d".repeat(64),
        domains: [],
      }),
      releaseActivationResolver: () => ({
        active: false,
        candidateCommit: RELEASE,
        activationCommit: RELEASE,
        coreVersion: IDENTITY.coreVersion,
        abiVersion: IDENTITY.abiVersion,
        sourceSha256: IDENTITY.sourceSha256,
        changedPathsSha256: "e".repeat(64),
      }),
    });
    assert.equal(gate.verificationKind, "domain-core-release-gate-inactive");
    assert.equal(gate.candidate.candidateCommit, RELEASE);
    assert.equal(gate.activation.activationCommit, RELEASE);
    assert.equal(gate.release.commit, RELEASE);
    assert.deepEqual(JSON.parse(readFileSync(output, "utf8")), gate);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("fails closed when the resolver reports an active domain-core lane", () => {
  const directory = mkdtempSync(join(tmpdir(), "active-functions-gate-"));
  const profile = join(directory, "profile.json");
  const output = join(directory, "gate.json");
  writeFileSync(
    profile,
    `${JSON.stringify({ candidateIdentity: IDENTITY })}\n`,
  );
  try {
    assert.throws(
      () =>
        prepareInactiveFunctionsReleaseGate({
          releaseCommit: RELEASE,
          releaseTag: "v1.0.40",
          profilePath: profile,
          outputPath: output,
          activationResolver: () => ({ active: true }),
        }),
      /requested while domain core is active/u,
    );
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
