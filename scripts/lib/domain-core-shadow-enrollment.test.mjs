import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";
import {
  clearDomainCoreShadowClaims,
  DOMAIN_CORE_SHADOW_CLAIMS,
  enrollmentMatches,
  mergeDomainCoreShadowClaims,
  normalizeDomainCoreShadowEnrollment,
  readDomainCoreShadowEnrollmentClaims,
} from "./domain-core-shadow-enrollment.mjs";

const CANDIDATE_COMMIT = "a".repeat(40);
const SOURCE_SHA256 = "b".repeat(64);
const CLI_PATH = "scripts/ops/manage-domain-core-shadow-enrollment.mjs";

function runCli(args) {
  return spawnSync(process.execPath, [CLI_PATH, ...args], {
    cwd: new URL("../..", import.meta.url),
    encoding: "utf8",
  });
}

function enrollment(overrides = {}) {
  const core = {
    version: "0.1.0",
    abiVersion: 3,
    sourceSha256: SOURCE_SHA256,
    ...overrides.expectedCore,
  };
  return normalizeDomainCoreShadowEnrollment(
    overrides.channel ?? "internal",
    overrides.consumers ?? ["windows", "apple", "windows"],
    overrides.candidateCommit ?? CANDIDATE_COMMIT,
    core,
  );
}

test("normalizes a candidate-bound enrollment and exact Rust identity", () => {
  assert.deepEqual(enrollment(), {
    channel: "internal",
    consumers: ["apple", "windows"],
    candidateCommit: CANDIDATE_COMMIT,
    expectedCore: {
      version: "0.1.0",
      abiVersion: 3,
      sourceSha256: SOURCE_SHA256,
    },
  });
  assert.equal(
    enrollment({ expectedCore: { abiVersion: "3" } }).expectedCore.abiVersion,
    3,
  );
});

test("merge, read, and clear preserve unrelated custom claims", () => {
  const expected = enrollment({ channel: "beta", consumers: ["apple"] });
  const merged = mergeDomainCoreShadowClaims({ paid: true }, expected);
  assert.deepEqual(merged, {
    paid: true,
    domainCoreShadowChannel: "beta",
    domainCoreShadowConsumers: ["apple"],
    domainCoreShadowCandidateCommit: CANDIDATE_COMMIT,
    domainCoreShadowCoreVersion: "0.1.0",
    domainCoreShadowCoreAbiVersion: 3,
    domainCoreShadowCoreSourceSha256: SOURCE_SHA256,
  });
  assert.deepEqual(readDomainCoreShadowEnrollmentClaims(merged), expected);
  assert.deepEqual(clearDomainCoreShadowClaims(merged), { paid: true });
});

test("clear revokes partial and malformed enrollment claims safely", () => {
  const partial = {
    paid: true,
    domainCoreShadowChannel: "internal",
    domainCoreShadowCandidateCommit: "not-a-commit",
    domainCoreShadowCoreVersion: "stale",
  };
  assert.deepEqual(clearDomainCoreShadowClaims(partial), { paid: true });
  assert.equal(readDomainCoreShadowEnrollmentClaims({ paid: true }), null);
});

test("verification requires exact channel, consumers, candidate, and Rust identity", () => {
  const expected = enrollment();
  const claims = mergeDomainCoreShadowClaims({}, expected);
  assert.equal(enrollmentMatches(claims, expected), true);

  for (const [claim, staleValue] of [
    [DOMAIN_CORE_SHADOW_CLAIMS.channel, "beta"],
    [DOMAIN_CORE_SHADOW_CLAIMS.consumers, ["apple"]],
    [DOMAIN_CORE_SHADOW_CLAIMS.candidateCommit, "c".repeat(40)],
    [DOMAIN_CORE_SHADOW_CLAIMS.coreVersion, "0.1.1"],
    [DOMAIN_CORE_SHADOW_CLAIMS.coreAbiVersion, 2],
    [DOMAIN_CORE_SHADOW_CLAIMS.coreSourceSha256, "d".repeat(64)],
  ]) {
    assert.equal(
      enrollmentMatches({ ...claims, [claim]: staleValue }, expected),
      false,
      claim,
    );
  }
});

test("partial, noncanonical, and type-confused claim sets fail closed", () => {
  const expected = enrollment();
  const claims = mergeDomainCoreShadowClaims({}, expected);
  for (const claim of Object.values(DOMAIN_CORE_SHADOW_CLAIMS)) {
    const partial = { ...claims };
    delete partial[claim];
    assert.equal(enrollmentMatches(partial, expected), false, claim);
    assert.throws(
      () => readDomainCoreShadowEnrollmentClaims(partial),
      /partial/,
    );
  }

  assert.equal(
    enrollmentMatches(
      { ...claims, domainCoreShadowConsumers: ["windows", "apple"] },
      expected,
    ),
    false,
  );
  assert.equal(
    enrollmentMatches(
      { ...claims, domainCoreShadowConsumers: ["apple", "apple", "windows"] },
      expected,
    ),
    false,
  );
  assert.equal(
    enrollmentMatches(
      { ...claims, domainCoreShadowCoreAbiVersion: "3" },
      expected,
    ),
    false,
  );
});

test("unknown channels and consumers are rejected", () => {
  assert.throws(() => enrollment({ channel: "production" }), /channel/);
  assert.throws(() => enrollment({ consumers: ["mystery"] }), /consumers/);
  assert.throws(() => enrollment({ consumers: [] }), /consumers/);
  assert.throws(
    () =>
      normalizeDomainCoreShadowEnrollment("internal", [3], CANDIDATE_COMMIT, {
        version: "0.1.0",
        abiVersion: 3,
        sourceSha256: SOURCE_SHA256,
      }),
    /consumers/,
  );
  assert.throws(
    () =>
      normalizeDomainCoreShadowEnrollment(
        "internal",
        ["apple", 3],
        CANDIDATE_COMMIT,
        {
          version: "0.1.0",
          abiVersion: 3,
          sourceSha256: SOURCE_SHA256,
        },
      ),
    /consumers/,
  );
});

test("candidate commit validation rejects abbreviated, uppercase, and decorated values", () => {
  for (const candidateCommit of [
    "a".repeat(39),
    "A".repeat(40),
    `sha:${CANDIDATE_COMMIT}`,
    `${CANDIDATE_COMMIT} `,
  ]) {
    assert.throws(() => enrollment({ candidateCommit }), /candidate commit/);
  }
});

test("core identity validation rejects malformed and partial tuples", () => {
  for (const version of [
    "1",
    "01.2.3",
    "1.02.3",
    "1.2.03",
    "v1.2.3",
    "1.2.3-01",
    "1.2.3 ",
  ]) {
    assert.throws(
      () => enrollment({ expectedCore: { version } }),
      /core version/,
    );
  }
  for (const abiVersion of [0, -1, 1.5, "03", "3.0", 4_294_967_296]) {
    assert.throws(
      () => enrollment({ expectedCore: { abiVersion } }),
      /ABI version/,
    );
  }
  for (const sourceSha256 of [
    "b".repeat(63),
    "B".repeat(64),
    `sha256:${SOURCE_SHA256}`,
    `${SOURCE_SHA256} `,
  ]) {
    assert.throws(
      () => enrollment({ expectedCore: { sourceSha256 } }),
      /source SHA-256/,
    );
  }
  assert.throws(
    () =>
      normalizeDomainCoreShadowEnrollment(
        "internal",
        ["apple"],
        CANDIDATE_COMMIT,
        null,
      ),
    /expected core identity/,
  );
  assert.throws(
    () =>
      normalizeDomainCoreShadowEnrollment(
        "internal",
        ["apple"],
        CANDIDATE_COMMIT,
        { version: "0.1.0" },
      ),
    /source SHA-256/,
  );
});

test("operator CLI help documents the full candidate-bound enrollment", () => {
  const result = runCli(["--help"]);
  assert.equal(result.status, 0, result.stderr);
  for (const option of [
    "--candidate-commit",
    "--core-version",
    "--core-abi-version",
    "--core-source-sha256",
    "--clear",
    "--verify",
  ]) {
    assert.match(result.stdout, new RegExp(option));
  }
});

test("operator CLI rejects partial enrollment and ambiguous revocation before Firebase access", () => {
  const partial = runCli([
    "--uid",
    "user-1",
    "--channel",
    "internal",
    "--consumers",
    "apple",
    "--candidate-commit",
    CANDIDATE_COMMIT,
  ]);
  assert.notEqual(partial.status, 0);
  assert.match(partial.stderr, /core version/);

  const ambiguousClear = runCli([
    "--uid",
    "user-1",
    "--clear",
    "--channel",
    "internal",
  ]);
  assert.notEqual(ambiguousClear.status, 0);
  assert.match(ambiguousClear.stderr, /cannot be combined/);

  const ambiguousVerify = runCli(["--uid", "user-1", "--verify", "--apply"]);
  assert.notEqual(ambiguousVerify.status, 0);
  assert.match(ambiguousVerify.stderr, /mutually exclusive/);
});
