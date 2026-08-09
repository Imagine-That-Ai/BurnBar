import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { verifyLocalDomainCoreIdentity } from "./verify-local-domain-core-identity.mjs";

const CANDIDATE = {
  candidateCommit: "a".repeat(40),
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};
const workspace = mkdtempSync(join(tmpdir(), "local-domain-core-identity-test-"));
const binaryPath = join(workspace, "domain-core-native-library");

function embeddedIdentity(candidate = CANDIDATE) {
  return (
    "openburnbar-domain-core-identity-v1" +
    `|candidateCommit=${candidate.candidateCommit}` +
    `|coreVersion=${candidate.coreVersion}` +
    `|abiVersion=${candidate.abiVersion}` +
    `|sourceSha256=${candidate.sourceSha256}`
  );
}

const binaryContents = Buffer.from(
  `exact local Rust binary\n${embeddedIdentity()}\0`,
  "utf8",
);
const binarySha256 = createHash("sha256").update(binaryContents).digest("hex");
writeFileSync(binaryPath, binaryContents);
const OBSERVED = { ...CANDIDATE, binarySha256 };

test.after(() => rmSync(workspace, { recursive: true, force: true }));

test("accepts an exact candidate-bound loaded Rust identity", () => {
  assert.deepEqual(
    verifyLocalDomainCoreIdentity(CANDIDATE.candidateCommit, OBSERVED, binaryPath),
    OBSERVED,
  );
});

test("rejects a report from a different or zero candidate", () => {
  for (const candidateCommit of ["c".repeat(40), "0".repeat(40)]) {
    assert.throws(
      () =>
        verifyLocalDomainCoreIdentity(
          CANDIDATE.candidateCommit,
          { ...OBSERVED, candidateCommit },
          binaryPath,
        ),
      /not bound to the local candidate/,
    );
  }
});

test("rejects a report that disagrees with the embedded identity", () => {
  assert.throws(
    () =>
      verifyLocalDomainCoreIdentity(
        CANDIDATE.candidateCommit,
        { ...OBSERVED, coreVersion: "0.3.1" },
        binaryPath,
      ),
    /reported Rust identity does not match embedded binary identity/,
  );
});

test("rejects a substituted binary", () => {
  const substitutedPath = join(workspace, "substituted-library");
  const substitutedContents = Buffer.from(
    `different local Rust binary\n${embeddedIdentity()}\0`,
    "utf8",
  );
  writeFileSync(substitutedPath, substitutedContents);
  assert.throws(
    () =>
      verifyLocalDomainCoreIdentity(
        CANDIDATE.candidateCommit,
        OBSERVED,
        substitutedPath,
      ),
    /binary digest does not match observed identity/,
  );
});

test("rejects malformed reports, symlinks, and directories", () => {
  assert.throws(
    () =>
      verifyLocalDomainCoreIdentity(
        CANDIDATE.candidateCommit,
        { ...OBSERVED, extra: true },
        binaryPath,
      ),
    /must contain exactly/,
  );

  const symlinkPath = join(workspace, "library-symlink");
  symlinkSync(binaryPath, symlinkPath);
  assert.throws(
    () =>
      verifyLocalDomainCoreIdentity(
        CANDIDATE.candidateCommit,
        OBSERVED,
        symlinkPath,
      ),
    /not a symlink/,
  );

  const directoryPath = join(workspace, "library-directory");
  mkdirSync(directoryPath);
  assert.throws(
    () =>
      verifyLocalDomainCoreIdentity(
        CANDIDATE.candidateCommit,
        OBSERVED,
        directoryPath,
      ),
    /nonempty regular file/,
  );
});
