import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";

const SCRIPT = new URL("./gh-api-with-retry.sh", import.meta.url);

function fixture({ failures = 0, exitCode = 1 } = {}) {
  const root = mkdtempSync(join(tmpdir(), "gh-api-with-retry-test-"));
  const bin = join(root, "bin");
  const countFile = join(root, "count");
  const argsFile = join(root, "args");
  mkdirSync(bin);
  const fakeGh = join(bin, "gh");
  writeFileSync(
    fakeGh,
    `#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "$FAKE_GH_COUNT_FILE" ]] || count="$(cat "$FAKE_GH_COUNT_FILE")"
count=$((count + 1))
printf '%s' "$count" > "$FAKE_GH_COUNT_FILE"
printf '%s\n' "$@" > "$FAKE_GH_ARGS_FILE"
if ((count <= FAKE_GH_FAILURES)); then
  printf 'discarded-partial-response-%s\n' "$count"
  echo "gh: transient service outage (HTTP 503)" >&2
  exit "$FAKE_GH_EXIT_CODE"
fi
printf 'success-payload\n'
`,
  );
  chmodSync(fakeGh, 0o755);
  return {
    root,
    countFile,
    argsFile,
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH}`,
      FAKE_GH_COUNT_FILE: countFile,
      FAKE_GH_ARGS_FILE: argsFile,
      FAKE_GH_FAILURES: String(failures),
      FAKE_GH_EXIT_CODE: String(exitCode),
      OPENBURNBAR_GH_API_ATTEMPTS: "3",
      OPENBURNBAR_GH_API_BASE_SLEEP_SECONDS: "0",
    },
  };
}

function run(args, env) {
  return spawnSync("bash", [SCRIPT.pathname, ...args], {
    env,
    encoding: "utf8",
  });
}

test("retries transient failures and emits only the successful response", () => {
  const fx = fixture({ failures: 2 });
  const result = run(["--paginate", "/repos/example/actions/runs"], fx.env);

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "success-payload\n");
  assert.match(result.stderr, /attempt 1\/3 failed/u);
  assert.match(result.stderr, /attempt 2\/3 failed/u);
  assert.equal(readFileSync(fx.countFile, "utf8"), "3");
  assert.equal(
    readFileSync(fx.argsFile, "utf8"),
    "api\n--paginate\n/repos/example/actions/runs\n",
  );
});

test("fails closed with the final gh exit code after the retry bound", () => {
  const fx = fixture({ failures: 3, exitCode: 23 });
  const result = run(["/repos/example"], fx.env);

  assert.equal(result.status, 23);
  assert.equal(result.stdout, "");
  assert.match(result.stderr, /failed after 3 attempts/u);
  assert.equal(readFileSync(fx.countFile, "utf8"), "3");
});

test("rejects invalid retry configuration before invoking gh", () => {
  const fx = fixture();
  const result = run(["/repos/example"], {
    ...fx.env,
    OPENBURNBAR_GH_API_ATTEMPTS: "0",
  });

  assert.equal(result.status, 2);
  assert.match(result.stderr, /must be a positive integer/u);
  assert.throws(() => readFileSync(fx.countFile, "utf8"));
});
