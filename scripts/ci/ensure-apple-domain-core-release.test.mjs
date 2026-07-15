import assert from "node:assert/strict";
import test from "node:test";

import {
  GhReleaseClient,
  ensureAppleRelease,
  validateRequest,
} from "./ensure-apple-domain-core-release.mjs";

const COMMIT = "a".repeat(40);
const OTHER = "b".repeat(40);
const REPOSITORY = "Imagine-That-Ai/BurnBar";

function release(overrides = {}) {
  return {
    tag_name: "v1.2.3",
    target_commitish: COMMIT,
    draft: true,
    prerelease: false,
    assets: [],
    ...overrides,
  };
}

function client({ existing = null, createStatus = 0, concurrent = null } = {}) {
  const mutations = [];
  let lookups = 0;
  return {
    mutations,
    resolveTagCommit: () => COMMIT,
    lookup: () => {
      lookups += 1;
      if (lookups === 1) return existing;
      return concurrent ?? release();
    },
    createDraft: (request) => {
      mutations.push(request);
      return { status: createStatus };
    },
  };
}

test("reuses an exact draft or published release without mutation", () => {
  for (const draft of [true, false]) {
    const gh = client({ existing: release({ draft }) });
    assert.deepEqual(
      ensureAppleRelease(
        { repository: REPOSITORY, tag: "v1.2.3", commit: COMMIT },
        gh,
      ),
      { created: false, draft },
    );
    assert.equal(gh.mutations.length, 0);
  }
});

test("creates an absent release only as an exact draft", () => {
  const gh = client();
  assert.deepEqual(
    ensureAppleRelease(
      { repository: REPOSITORY, tag: "v1.2.3", commit: COMMIT },
      gh,
    ),
    { created: true, draft: true },
  );
  assert.equal(gh.mutations.length, 1);
});

test("creation collision succeeds only for an exact concurrent release", () => {
  const exact = client({ createStatus: 1, concurrent: release() });
  assert.deepEqual(
    ensureAppleRelease(
      { repository: REPOSITORY, tag: "v1.2.3", commit: COMMIT },
      exact,
    ),
    { created: false, draft: true },
  );
  for (const substituted of [
    release({ target_commitish: OTHER }),
    release({ prerelease: true }),
    release({ tag_name: "v1.2.4" }),
  ]) {
    const gh = client({ createStatus: 1, concurrent: substituted });
    assert.throws(
      () =>
        ensureAppleRelease(
          { repository: REPOSITORY, tag: "v1.2.3", commit: COMMIT },
          gh,
        ),
      /must match the exact/,
    );
  }
});

test("rejects moved tags and malformed request identity before mutation", () => {
  const gh = client();
  gh.resolveTagCommit = () => OTHER;
  assert.throws(
    () =>
      ensureAppleRelease(
        { repository: REPOSITORY, tag: "v1.2.3", commit: COMMIT },
        gh,
      ),
    /does not resolve/,
  );
  assert.equal(gh.mutations.length, 0);
  for (const request of [
    { repository: "attacker/repo", tag: "v1.2.3", commit: COMMIT },
    { repository: REPOSITORY, tag: "1.2.3", commit: COMMIT },
    { repository: REPOSITORY, tag: "v1.2.3", commit: "abc" },
    { repository: REPOSITORY, tag: "v1.2.3", commit: COMMIT, extra: true },
  ]) {
    assert.throws(() => validateRequest(request));
  }
});

test("derives prerelease only from the SemVer prerelease component", () => {
  assert.equal(
    validateRequest({
      repository: REPOSITORY,
      tag: "v1.2.3-beta.1+build-7",
      commit: COMMIT,
    }).prerelease,
    true,
  );
  assert.equal(
    validateRequest({
      repository: REPOSITORY,
      tag: "v1.2.3+build-7",
      commit: COMMIT,
    }).prerelease,
    false,
  );
});

test("draft creation omits undocumented prerelease=false and uses prerelease only when needed", () => {
  const calls = [];
  const gh = new GhReleaseClient(REPOSITORY, (_command, arguments_) => {
    calls.push(arguments_);
    return { status: 0, stdout: "", stderr: "" };
  });
  gh.createDraft(
    validateRequest({ repository: REPOSITORY, tag: "v1.2.3", commit: COMMIT }),
  );
  gh.createDraft(
    validateRequest({
      repository: REPOSITORY,
      tag: "v1.2.3-beta.1",
      commit: COMMIT,
    }),
  );
  assert.equal(calls[0].includes("--prerelease"), false);
  assert.equal(calls[0].includes("--prerelease=false"), false);
  assert.equal(calls[1].includes("--prerelease"), true);
});
