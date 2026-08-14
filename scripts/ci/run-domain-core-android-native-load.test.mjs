import assert from "node:assert/strict";
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, win32 } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import test from "node:test";

import {
  isDirectInvocation,
  selectCanonicalCandidateCommit,
  validateCandidateCommit,
} from "./canonical-candidate-commit.mjs";

const SCRIPT = resolve(
  new URL("./run-domain-core-android-native-load.sh", import.meta.url).pathname,
);
const CANONICAL_CANDIDATE_SCRIPT = fileURLToPath(
  new URL("./canonical-candidate-commit.mjs", import.meta.url),
);
const CANDIDATE = "a".repeat(40);

function fixture(context, mode = "success") {
  const directory = mkdtempSync(join(tmpdir(), "domain-core-adb-"));
  const adb = join(directory, "adb");
  const apk = join(directory, "domain-core-test.apk");
  const output = join(directory, "observed", "identity.json");
  writeFileSync(apk, "apk");
  writeFileSync(
    adb,
    `#!/usr/bin/env bash
set -euo pipefail
mode="\${FAKE_ADB_MODE:-success}"
if [[ "$1 $2 $3 $4" == "install -r -t ${apk}" ]]; then echo Success; exit 0; fi
if [[ "$1" == "uninstall" ]]; then echo Success; exit 0; fi
if [[ "$1 $2 $3 $4" == "shell pm list instrumentation"* ]]; then
  if [[ "$mode" == "missing" ]]; then
    echo 'instrumentation:example.other/Runner (target=example.target)'
  else
    echo 'instrumentation:example.other/Runner (target=example.target)'
    echo 'instrumentation:com.openburnbar.domaincore.test/androidx.test.runner.AndroidJUnitRunner (target=com.openburnbar.domaincore.test)'
  fi
  exit 0
fi
if [[ "$1 $2 $3" == "shell am instrument" ]]; then echo 'OK (5 tests)'; exit 0; fi
if [[ "$1 $2 $3" == "shell run-as com.openburnbar.domaincore.test" && "$4" == "pwd" ]]; then
  echo '/data/user/0/com.openburnbar.domaincore.test'; exit 0
fi
if [[ "$1 $2 $3 $4" == "exec-out run-as com.openburnbar.domaincore.test cat" ]]; then
  if [[ "$mode" == "invalid-json" ]]; then echo 'run-as: package not debuggable'; exit 0; fi
  if [[ "$mode" == "read-error" ]]; then echo 'remote cat failed' >&2; exit 9; fi
  printf '%s\n' '{"candidateCommit":"${CANDIDATE}","coreVersion":"0.3.0","abiVersion":3,"sourceSha256":"${"b".repeat(64)}","binarySha256":"${"c".repeat(64)}"}'
  exit 0
fi
echo "unexpected fake adb invocation: $*" >&2
exit 98
`,
  );
  chmodSync(adb, 0o755);
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  return { adb, apk, output, mode };
}

function execute(paths) {
  return spawnSync("bash", [SCRIPT, paths.apk, CANDIDATE, paths.output], {
    encoding: "utf8",
    env: { ...process.env, ADB: paths.adb, FAKE_ADB_MODE: paths.mode },
  });
}

test("installs, resolves, runs, and validates the exact instrumentation identity", (context) => {
  const paths = fixture(context);
  const result = execute(paths);
  assert.equal(result.status, 0, result.stderr);
  const identity = JSON.parse(readFileSync(paths.output, "utf8"));
  assert.equal(identity.candidateCommit, CANDIDATE);
  assert.equal(identity.binarySha256, "c".repeat(64));
  assert.match(result.stderr, /Verified loaded Android Rust identity/u);
});

test("rejects ambiguous or absent self-targeting instrumentation", (context) => {
  const paths = fixture(context, "missing");
  const result = execute(paths);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Expected exactly one installed self-targeting/u);
});

test("keeps run-as diagnostics out of the JSON contract", (context) => {
  const paths = fixture(context, "invalid-json");
  const result = execute(paths);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /invalid JSON/u);
});

test("reports extraction stderr instead of publishing a partial identity", (context) => {
  const paths = fixture(context, "read-error");
  const result = execute(paths);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /Unable to read the observed Android Rust identity/u);
  assert.match(result.stderr, /remote cat failed/u);
});

// ── Canonical candidate-commit selection ───────────────────────────────────
//
// The native-load script receives the candidate commit as argv[2].  On
// pull_request events GITHUB_SHA is the synthetic merge commit GitHub creates
// at refs/pull/{n}/merge — an ephemeral SHA that must never be embedded into a
// build artifact or used as the expected identity.  The canonical selector
// resolves the real PR head SHA (or the exact GITHUB_SHA for push/dispatch),
// and fails closed on every missing, malformed, or mismatched coordinate.

const PR_HEAD = "71a1e0c020f6a33616d39443f66e4a1961b1ed87";
const PUSH_SHA = "255eccfc3b2e7d8a9c0f3a1b2c3d4e5f6a7b8c9d";
const MERGE_SHA = "0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f";

test("pull_request selects the exact event head SHA, not the synthetic merge SHA", () => {
  const selected = selectCanonicalCandidateCommit({
    event: "pull_request",
    payload: { pull_request: { head: { sha: PR_HEAD } } },
    fallbackSha: MERGE_SHA,
  });
  assert.equal(selected, PR_HEAD);
  assert.notEqual(selected, MERGE_SHA);
});

test("push and workflow_dispatch select the exact GITHUB_SHA", () => {
  for (const event of ["push", "workflow_dispatch"]) {
    const selected = selectCanonicalCandidateCommit({
      event,
      payload: {},
      fallbackSha: PUSH_SHA,
    });
    assert.equal(selected, PUSH_SHA, `${event} must return GITHUB_SHA`);
  }
});

test("merge_group selects the exact synthetic queue candidate and cross-checks GITHUB_SHA", () => {
  const selected = selectCanonicalCandidateCommit({
    event: "merge_group",
    payload: { merge_group: { head_sha: MERGE_SHA } },
    fallbackSha: MERGE_SHA,
  });
  assert.equal(selected, MERGE_SHA);

  assert.throws(
    () => selectCanonicalCandidateCommit({
      event: "merge_group",
      payload: { merge_group: { head_sha: MERGE_SHA } },
      fallbackSha: PR_HEAD,
    }),
    /does not match fallbackSha/u,
  );
});

test("missing or malformed merge_group coordinates fail closed", () => {
  const cases = [
    { payload: null, fallbackSha: MERGE_SHA, message: /requires a payload/u },
    {
      payload: {},
      fallbackSha: MERGE_SHA,
      message: /missing the merge_group object/u,
    },
    {
      payload: { merge_group: {} },
      fallbackSha: MERGE_SHA,
      message: /full lowercase 40-character/u,
    },
    {
      payload: { merge_group: { head_sha: MERGE_SHA } },
      fallbackSha: undefined,
      message: /full lowercase 40-character/u,
    },
  ];
  for (const { payload, fallbackSha, message } of cases) {
    assert.throws(
      () => selectCanonicalCandidateCommit({
        event: "merge_group",
        payload,
        fallbackSha,
      }),
      message,
    );
  }
});

test("missing or malformed pull_request coordinates fail closed", () => {
  const validPayload = { pull_request: { head: { sha: PR_HEAD } } };
  const cases = [
    {
      name: "null payload",
      input: { event: "pull_request", payload: null, fallbackSha: MERGE_SHA },
      message: /requires a payload/u,
    },
    {
      name: "missing pull_request object",
      input: { event: "pull_request", payload: {}, fallbackSha: MERGE_SHA },
      message: /missing the pull_request object/u,
    },
    {
      name: "missing head object",
      input: {
        event: "pull_request",
        payload: { pull_request: {} },
        fallbackSha: MERGE_SHA,
      },
      message: /missing the head object/u,
    },
    {
      name: "head.sha not a string",
      input: {
        event: "pull_request",
        payload: { pull_request: { head: { sha: 42 } } },
        fallbackSha: MERGE_SHA,
      },
      message: /head\.sha is not a string/u,
    },
    {
      name: "head.sha undefined",
      input: {
        event: "pull_request",
        payload: { pull_request: { head: {} } },
        fallbackSha: MERGE_SHA,
      },
      message: /head\.sha is not a string/u,
    },
  ];
  for (const { name, input, message } of cases) {
    assert.throws(
      () => selectCanonicalCandidateCommit(input),
      message,
      `${name} should fail closed`,
    );
  }
  // Ensure the valid payload still passes for contrast.
  assert.equal(
    selectCanonicalCandidateCommit({
      event: "pull_request",
      payload: validPayload,
      fallbackSha: MERGE_SHA,
    }),
    PR_HEAD,
  );
});

test("missing or malformed GITHUB_SHA for push/dispatch fails closed", () => {
  const cases = [
    {
      name: "missing fallbackSha",
      input: { event: "push", payload: {} },
      message: /requires fallbackSha/u,
    },
    {
      name: "undefined fallbackSha",
      input: { event: "push", payload: {}, fallbackSha: undefined },
      message: /requires fallbackSha/u,
    },
    {
      name: "empty fallbackSha",
      input: { event: "push", payload: {}, fallbackSha: "" },
      message: /full lowercase 40-character/u,
    },
    {
      name: "uppercase hex",
      input: { event: "push", payload: {}, fallbackSha: PR_HEAD.toUpperCase() },
      message: /full lowercase 40-character/u,
    },
    {
      name: "39 characters",
      input: { event: "push", payload: {}, fallbackSha: "a".repeat(39) },
      message: /full lowercase 40-character/u,
    },
    {
      name: "41 characters",
      input: { event: "push", payload: {}, fallbackSha: "a".repeat(41) },
      message: /full lowercase 40-character/u,
    },
    {
      name: "non-hex characters",
      input: { event: "push", payload: {}, fallbackSha: "g".repeat(40) },
      message: /full lowercase 40-character/u,
    },
  ];
  for (const { name, input, message } of cases) {
    assert.throws(
      () => selectCanonicalCandidateCommit(input),
      message,
      `${name} should fail closed`,
    );
  }
});

test("unsupported or unknown event names fail closed", () => {
  for (const event of ["schedule", "issue_comment", "pull_request_review", ""]) {
    assert.throws(
      () => selectCanonicalCandidateCommit({ event, fallbackSha: PUSH_SHA }),
      /unsupported GitHub event/u,
      `event "${event}" should be rejected`,
    );
  }
});

test("validateCandidateCommit accepts only full lowercase 40-hex SHAs", () => {
  assert.equal(validateCandidateCommit(PR_HEAD), PR_HEAD);
  assert.equal(validateCandidateCommit("0".repeat(40)), "0".repeat(40));
  for (const bad of ["", "abc", PR_HEAD.toUpperCase(), "a".repeat(39), "a".repeat(41), "g".repeat(40), 42, null, undefined]) {
    assert.throws(
      () => validateCandidateCommit(bad),
      /full lowercase 40-character/u,
      `validateCandidateCommit(${JSON.stringify(bad)}) should throw`,
    );
  }
});

test("synthetic PR merge SHA cannot substitute for the canonical PR head identity", () => {
  // A real PR has distinct head and merge SHAs.  The selector must return the
  // head SHA and must never silently fall back to the merge SHA even when the
  // payload is well-formed.  If the head.sha were accidentally set to the
  // merge SHA, validation would still pass (both are 40-hex), so this test
  // pins the *selection* contract: the selector returns whatever
  // payload.pull_request.head.sha is, and the workflow must feed the head SHA
  // there, never the merge SHA.
  const headPayload = { pull_request: { head: { sha: PR_HEAD } } };
  const selected = selectCanonicalCandidateCommit({
    event: "pull_request",
    payload: headPayload,
    fallbackSha: MERGE_SHA,
  });
  assert.equal(selected, PR_HEAD);
  assert.notEqual(selected, MERGE_SHA);
  // Conversely, if someone wrongly puts the merge SHA in head.sha, the
  // selector dutifully returns it — proving the selector trusts the payload.
  // The defense against merge SHA substitution is the workflow step that
  // populates head.sha from github.event.pull_request.head.sha, not the
  // selector itself.  This test documents that boundary.
  const tamperedPayload = { pull_request: { head: { sha: MERGE_SHA } } };
  assert.equal(
    selectCanonicalCandidateCommit({
      event: "pull_request",
      payload: tamperedPayload,
      fallbackSha: PR_HEAD,
    }),
    MERGE_SHA,
  );
});

test("canonical candidate CLI entrypoint detection handles Windows paths", () => {
  assert.equal(
    isDirectInvocation(
      "C:\\a\\BurnBar\\scripts\\ci\\canonical-candidate-commit.mjs",
      "C:\\a\\BurnBar\\scripts\\ci\\nested\\..\\canonical-candidate-commit.mjs",
      win32.resolve,
    ),
    true,
  );
  assert.equal(
    isDirectInvocation(
      "C:\\a\\BurnBar\\scripts\\ci\\canonical-candidate-commit.mjs",
      "D:\\a\\BurnBar\\scripts\\ci\\canonical-candidate-commit.mjs",
      win32.resolve,
    ),
    false,
  );
  assert.equal(
    isDirectInvocation(
      "C:\\a\\BurnBar\\scripts\\ci\\canonical-candidate-commit.mjs",
      undefined,
      win32.resolve,
    ),
    false,
  );
});

test("canonical candidate CLI writes the selected commit to GitHub output", (context) => {
  const directory = mkdtempSync(join(tmpdir(), "canonical-candidate-cli-"));
  context.after(() => rmSync(directory, { recursive: true, force: true }));
  const eventPath = join(directory, "event.json");
  const githubOutput = join(directory, "github-output.txt");
  writeFileSync(
    eventPath,
    JSON.stringify({ pull_request: { head: { sha: PR_HEAD } } }),
  );

  const result = spawnSync(process.execPath, [CANONICAL_CANDIDATE_SCRIPT], {
    encoding: "utf8",
    env: {
      ...process.env,
      GITHUB_EVENT_NAME: "pull_request",
      GITHUB_EVENT_PATH: eventPath,
      GITHUB_SHA: MERGE_SHA,
      GITHUB_OUTPUT: githubOutput,
    },
  });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), PR_HEAD);
  assert.equal(readFileSync(githubOutput, "utf8"), `candidate_commit=${PR_HEAD}\n`);
});
