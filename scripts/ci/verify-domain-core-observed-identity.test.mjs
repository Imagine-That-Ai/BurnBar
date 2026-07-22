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

import { verifyObservedIdentity } from "./verify-domain-core-observed-identity.mjs";

const CANDIDATE = {
  candidateCommit: "a".repeat(40),
  coreVersion: "0.3.0",
  abiVersion: 3,
  sourceSha256: "b".repeat(64),
};

const PROFILE = {
  name: "public-production",
  artifactAuthority: "signed",
  distribution: "public",
  candidateIdentity: CANDIDATE,
};

const workspace = mkdtempSync(join(tmpdir(), "domain-core-identity-test-"));
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
  `exact shipped Rust binary\n${embeddedIdentity()}\0`,
  "utf8",
);
const binarySha256 = createHash("sha256").update(binaryContents).digest("hex");
writeFileSync(binaryPath, binaryContents);

const OBSERVED = { ...CANDIDATE, binarySha256 };

test.after(() => rmSync(workspace, { recursive: true, force: true }));

test("accepts the exact loaded Rust identity", () => {
  assert.deepEqual(verifyObservedIdentity(PROFILE, OBSERVED, binaryPath), {
    ...CANDIDATE,
    binarySha256,
  });
});

test("rejects every reported candidate tuple substitution", () => {
  for (const [key, value] of [
    ["candidateCommit", "c".repeat(40)],
    ["coreVersion", "0.3.1"],
    ["abiVersion", 4],
    ["sourceSha256", "d".repeat(64)],
  ]) {
    assert.throws(
      () =>
        verifyObservedIdentity(
          PROFILE,
          { ...OBSERVED, [key]: value },
          binaryPath,
        ),
      /reported Rust identity does not match selected signed profile/,
    );
  }
});

test("rejects missing, extra, and malformed binary digests", () => {
  const { binarySha256: _removed, ...missing } = OBSERVED;
  assert.throws(
    () => verifyObservedIdentity(PROFILE, missing, binaryPath),
    /must contain exactly/,
  );
  assert.throws(
    () =>
      verifyObservedIdentity(
        PROFILE,
        { ...OBSERVED, unexpected: true },
        binaryPath,
      ),
    /must contain exactly/,
  );
  assert.throws(
    () =>
      verifyObservedIdentity(
        PROFILE,
        { ...OBSERVED, binarySha256: binarySha256.toUpperCase() },
        binaryPath,
      ),
    /lowercase SHA-256 digest/,
  );
});

test("rejects a substituted shipped binary", () => {
  const substituted = join(workspace, "substituted-library");
  const substitutedContents = Buffer.from(
    `different native binary\n${embeddedIdentity()}\0`,
    "utf8",
  );
  writeFileSync(substituted, substitutedContents);
  assert.throws(
    () => verifyObservedIdentity(PROFILE, OBSERVED, substituted),
    /binary digest does not match observed identity/,
  );
});

test("rejects a missing, wrong, zero, or ambiguous embedded identity", () => {
  const cases = [
    [
      "missing",
      "no embedded identity\n",
      /exactly one canonical embedded identity; found 0/,
    ],
    [
      "wrong",
      `${embeddedIdentity({ ...CANDIDATE, candidateCommit: "c".repeat(40) })}\0`,
      /embedded Rust identity does not match selected signed profile/,
    ],
    [
      "zero",
      `${embeddedIdentity({ ...CANDIDATE, candidateCommit: "0".repeat(40) })}\0`,
      /embedded Rust identity does not match selected signed profile/,
    ],
    [
      "ambiguous",
      `${embeddedIdentity()}\0${embeddedIdentity()}\0`,
      /exactly one canonical embedded identity; found 2/,
    ],
  ];
  for (const [name, contents, expectedError] of cases) {
    const path = join(workspace, `${name}-identity-library`);
    const bytes = Buffer.from(contents, "utf8");
    writeFileSync(path, bytes);
    const observed = {
      ...OBSERVED,
      binarySha256: createHash("sha256").update(bytes).digest("hex"),
    };
    assert.throws(
      () => verifyObservedIdentity(PROFILE, observed, path),
      expectedError,
      name,
    );
  }
});

test("rejects symlinks and non-regular binary paths", () => {
  const symlink = join(workspace, "library-symlink");
  symlinkSync(binaryPath, symlink);
  assert.throws(
    () => verifyObservedIdentity(PROFILE, OBSERVED, symlink),
    /nonempty regular file, not a symlink/,
  );

  const directory = join(workspace, "library-directory");
  mkdirSync(directory);
  assert.throws(
    () => verifyObservedIdentity(PROFILE, OBSERVED, directory),
    /nonempty regular file, not a symlink/,
  );
});

test("rejects unsigned, private, and incomplete profiles", () => {
  assert.throws(() =>
    verifyObservedIdentity(
      { ...PROFILE, artifactAuthority: "development" },
      OBSERVED,
      binaryPath,
    ),
  );
  assert.throws(() =>
    verifyObservedIdentity(
      { ...PROFILE, distribution: "internal" },
      OBSERVED,
      binaryPath,
    ),
  );
  assert.throws(() =>
    verifyObservedIdentity(
      { ...PROFILE, candidateIdentity: null },
      OBSERVED,
      binaryPath,
    ),
  );
});
