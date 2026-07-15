import assert from "node:assert/strict";
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

test("accepts the exact loaded Rust identity", () => {
  assert.deepEqual(verifyObservedIdentity(PROFILE, CANDIDATE), CANDIDATE);
});

test("rejects every candidate tuple substitution", () => {
  for (const [key, value] of [
    ["candidateCommit", "c".repeat(40)],
    ["coreVersion", "0.3.1"],
    ["abiVersion", 4],
    ["sourceSha256", "d".repeat(64)],
  ]) {
    assert.throws(
      () => verifyObservedIdentity(PROFILE, { ...CANDIDATE, [key]: value }),
      /does not match selected signed profile/,
    );
  }
});

test("rejects unsigned, private, and incomplete profiles", () => {
  assert.throws(() =>
    verifyObservedIdentity(
      { ...PROFILE, artifactAuthority: "development" },
      CANDIDATE,
    ),
  );
  assert.throws(() =>
    verifyObservedIdentity({ ...PROFILE, distribution: "internal" }, CANDIDATE),
  );
  assert.throws(() =>
    verifyObservedIdentity({ ...PROFILE, candidateIdentity: null }, CANDIDATE),
  );
});
