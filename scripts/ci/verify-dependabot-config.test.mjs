#!/usr/bin/env node
// Proves verify-dependabot-config.mjs actually fails on the two regressions it
// exists to catch. A guard that cannot fail is decoration, so every negative
// case below asserts a non-zero exit AND that the message names the real cause.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = new URL("./verify-dependabot-config.mjs", import.meta.url).pathname;

function entry(dir, ecosystem = "npm") {
  return `  - package-ecosystem: "${ecosystem}"
    directory: "${dir}"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 2
`;
}

/** Build a throwaway repo: a dependabot.yml plus a lockfile in each of `lockDirs`. */
function scaffold({ config, lockDirs }) {
  const root = mkdtempSync(join(tmpdir(), "dependabot-check-"));
  mkdirSync(join(root, ".github"), { recursive: true });
  writeFileSync(join(root, ".github", "dependabot.yml"), config);
  for (const d of lockDirs) {
    const abs = d === "/" ? root : join(root, d);
    mkdirSync(abs, { recursive: true });
    writeFileSync(join(abs, "package-lock.json"), '{"lockfileVersion":3}');
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

const cases = [];
const test = (n, f) => cases.push([n, f]);

test("passes when every lockfile has an npm entry and no aliases are used", () => {
  const root = scaffold({
    config: `version: 2\nupdates:\n${entry("/")}${entry("/apps/web")}`,
    lockDirs: ["/", "apps/web"],
  });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 0, `expected pass, got:\n${out}`);
  assert.match(out, /all 2 npm lockfiles have an auto-fix owner/);
});

test("FAILS on a YAML anchor definition (Dependabot rejects the whole file)", () => {
  const root = scaffold({
    config: `version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    schedule: &weekly
      interval: "weekly"
`,
    lockDirs: ["/"],
  });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 1, `expected failure, got:\n${out}`);
  assert.match(out, /YAML anchor\/alias found/);
  assert.match(out, /dependabot-core#1582/);
});

test("FAILS on a YAML merge-key alias (<<: *name)", () => {
  const root = scaffold({
    config: `version: 2
updates:
  - package-ecosystem: "npm"
    directory: "/"
    <<: *defaults
`,
    lockDirs: ["/"],
  });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 1, `expected failure, got:\n${out}`);
  assert.match(out, /YAML anchor\/alias found/);
});

test("FAILS when a lockfile has no auto-fix owner (the #1968 regression)", () => {
  const root = scaffold({
    config: `version: 2\nupdates:\n${entry("/")}`,
    lockDirs: ["/", "tools/schema-sync"],
  });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 1, `expected failure, got:\n${out}`);
  assert.match(out, /no npm entry/);
  assert.match(out, /\/tools\/schema-sync/);
});

test("FAILS on duplicate ecosystem+directory pairs", () => {
  const root = scaffold({
    config: `version: 2\nupdates:\n${entry("/")}${entry("/")}`,
    lockDirs: ["/"],
  });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 1, `expected failure, got:\n${out}`);
  assert.match(out, /entries for "npm \/"/);
});

test("ignores lockfiles under node_modules and other build output", () => {
  const root = scaffold({
    config: `version: 2\nupdates:\n${entry("/")}`,
    lockDirs: ["/", "node_modules/left-pad", "build/x", "Vendor/libsignal"],
  });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 0, `vendored/build lockfiles must not be required, got:\n${out}`);
});

test("does not mistake prose in comments for an anchor", () => {
  const root = scaffold({
    config: `version: 2
# Do not de-duplicate with anchors: Dependabot rejects & and * aliases outright.
updates:
${entry("/")}`,
    lockDirs: ["/"],
  });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 0, `comment prose must not trip the anchor check, got:\n${out}`);
});

test("FAILS loudly if the file shape changes so the check goes blind", () => {
  const root = scaffold({ config: "version: 2\nupdates: []\n", lockDirs: ["/"] });
  const { code, out } = run(root);
  rmSync(root, { recursive: true, force: true });
  assert.equal(code, 1, `expected failure, got:\n${out}`);
  assert.match(out, /parsed zero update entries/);
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
