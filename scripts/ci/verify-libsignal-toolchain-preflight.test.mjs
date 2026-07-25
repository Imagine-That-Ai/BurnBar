#!/usr/bin/env node
// Proves verify-libsignal-toolchain-preflight.mjs fails on the exact shapes that
// caused the outage, and does NOT fire on the shapes that are already correct.
// The false-positive cases are load-bearing: an earlier draft matched these
// filenames inside hashFiles(...) cache keys and on.*.paths filters, which
// flagged eight correctly-ordered jobs and would have blocked every PR.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = new URL("./verify-libsignal-toolchain-preflight.mjs", import.meta.url).pathname;

function scaffold(workflows) {
  const root = mkdtempSync(join(tmpdir(), "toolchain-preflight-"));
  mkdirSync(join(root, ".github", "workflows"), { recursive: true });
  for (const [name, body] of Object.entries(workflows)) {
    writeFileSync(join(root, ".github", "workflows", name), body);
  }
  return root;
}

function run(root) {
  try {
    return { code: 0, out: execFileSync("node", [SCRIPT], { cwd: root, encoding: "utf8" }) };
  } catch (err) {
    return { code: err.status ?? 1, out: `${err.stdout ?? ""}${err.stderr ?? ""}` };
  }
}

const GOOD = `name: good
on:
  pull_request:
    paths:
      - "scripts/test-openburnbar-swift.sh"
jobs:
  swift:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v5
      - name: Cache macOS Signal FFI artifact
        uses: actions/cache@v5
        with:
          key: \${{ runner.os }}-signal-ffi-macos-\${{ hashFiles('scripts/build-signal-ffi-xcframework.sh') }}
      - name: Ensure libsignal native toolchain (protoc + cmake)
        uses: ./.github/actions/ensure-libsignal-toolchain
      - name: Run Swift tests
        run: ./scripts/test-openburnbar-swift.sh
`;

const cases = [];
const test = (n, f) => cases.push([n, f]);

test("passes a correctly ordered job, ignoring hashFiles and paths mentions", () => {
  const root = scaffold({ "good.yml": GOOD });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 0, `expected pass, got:\n${out}`);
  assert.match(out, /all 1 jobs/);
});

test("FAILS when an FFI job has no preflight at all (the #1969 outage)", () => {
  const root = scaffold({
    "bad.yml": `name: bad
jobs:
  swift:
    steps:
      - uses: actions/checkout@v5
      - run: ./scripts/test-openburnbar-swift.sh
`,
  });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 1, `expected failure, got:\n${out}`);
  assert.match(out, /never uses \.\/\.github\/actions\/ensure-libsignal-toolchain/);
  assert.match(out, /cmake/);
});

test("FAILS on the protobuf-only preflight, incl. the codeql-pr one-liner form", () => {
  const root = scaffold({
    "codeqlish.yml": `name: codeqlish
jobs:
  analyze:
    steps:
      - uses: actions/checkout@v5
      - name: Install protobuf for Swift Signal FFI
        run: |
          if ! command -v protoc >/dev/null 2>&1; then brew install protobuf; fi
          protoc --version
      - run: SIGNAL_FFI_BUILD_TARGETS=x86_64-apple-darwin ./scripts/build-signal-ffi-xcframework.sh
`,
  });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 1, `expected failure, got:\n${out}`);
  assert.match(out, /installs protobuf by hand/);
});

test("FAILS when the preflight runs after the build", () => {
  const root = scaffold({
    "late.yml": `name: late
jobs:
  swift:
    steps:
      - uses: actions/checkout@v5
      - run: ./scripts/test-openburnbar-swift.sh
      - uses: ./.github/actions/ensure-libsignal-toolchain
`,
  });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 1, `expected failure, got:\n${out}`);
  assert.match(out, /only AFTER the FFI build step/);
});

test("does not treat an on.*.paths filter alone as an FFI build", () => {
  const root = scaffold({
    "pathsonly.yml": `name: pathsonly
on:
  pull_request:
    paths:
      - "scripts/test-openburnbar-mobile.sh"
jobs:
  lint:
    steps:
      - run: echo hi
`,
    "good.yml": GOOD,
  });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 0, `paths filters must not count as builds, got:\n${out}`);
  assert.match(out, /all 1 jobs/, "only the real build job should be counted");
});

test("goes loud rather than silently passing when no FFI job is found", () => {
  const root = scaffold({ "none.yml": "name: none\njobs:\n  a:\n    steps:\n      - run: true\n" });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 1, `expected failure, got:\n${out}`);
  assert.match(out, /gone blind/);
});

let failed = 0;
for (const [name, fn] of cases) {
  try {
    fn();
    console.log(`ok - ${name}`);
  } catch (err) {
    failed += 1;
    console.error(`not ok - ${name}\n    ${err.message}`);
  }
}
console.log(`\n${cases.length - failed}/${cases.length} passed`);
process.exit(failed ? 1 : 0);
