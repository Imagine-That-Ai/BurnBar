import assert from "node:assert/strict";
import test from "node:test";

import {
  run,
  validateNativeReleaseEventCommit,
} from "./verify-domain-core-native-event-commit.mjs";

const EVENT_COMMIT = "a".repeat(40);
const OTHER_COMMIT = "b".repeat(40);

test("tag push accepts only the release commit at GITHUB_SHA", () => {
  assert.deepEqual(
    validateNativeReleaseEventCommit({
      eventName: "push",
      eventCommit: EVENT_COMMIT,
      releaseCommit: EVENT_COMMIT,
    }),
    {
      eventName: "push",
      eventCommit: EVENT_COMMIT,
      releaseCommit: EVENT_COMMIT,
    },
  );
  assert.throws(
    () =>
      validateNativeReleaseEventCommit({
        eventName: "push",
        eventCommit: EVENT_COMMIT,
        releaseCommit: OTHER_COMMIT,
      }),
    /must equal GITHUB_SHA/,
  );
});

test("workflow_dispatch may resolve an explicitly selected release commit", () => {
  assert.deepEqual(
    validateNativeReleaseEventCommit({
      eventName: "workflow_dispatch",
      eventCommit: EVENT_COMMIT,
      releaseCommit: OTHER_COMMIT,
    }),
    {
      eventName: "workflow_dispatch",
      eventCommit: EVENT_COMMIT,
      releaseCommit: OTHER_COMMIT,
    },
  );
});

test("rejects untrusted event kinds and malformed commit identities", () => {
  assert.throws(
    () =>
      validateNativeReleaseEventCommit({
        eventName: "pull_request",
        eventCommit: EVENT_COMMIT,
        releaseCommit: EVENT_COMMIT,
      }),
    /must be push or workflow_dispatch/,
  );
  for (const [eventCommit, releaseCommit] of [
    ["abc", EVENT_COMMIT],
    [EVENT_COMMIT.toUpperCase(), EVENT_COMMIT],
    [EVENT_COMMIT, "abc"],
    [EVENT_COMMIT, OTHER_COMMIT.toUpperCase()],
  ]) {
    assert.throws(() =>
      validateNativeReleaseEventCommit({
        eventName: "workflow_dispatch",
        eventCommit,
        releaseCommit,
      }),
    );
  }
});

test("CLI rejects reordered, duplicate, and incomplete arguments", () => {
  assert.throws(
    () =>
      run([
        "--event-commit",
        EVENT_COMMIT,
        "--event-name",
        "push",
        "--release-commit",
        EVENT_COMMIT,
      ]),
    /usage/,
  );
  assert.throws(
    () =>
      run([
        "--event-name",
        "push",
        "--event-commit",
        EVENT_COMMIT,
        "--event-commit",
        EVENT_COMMIT,
      ]),
    /usage/,
  );
  assert.throws(() => run(["--event-name", "push"]), /usage/);
});
