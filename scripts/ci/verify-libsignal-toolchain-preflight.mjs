#!/usr/bin/env node
// Keeps the cmake regression from coming back.
//
// boring-sys (BoringSSL, pulled in by Vendor/libsignal) shells out to `cmake`
// from its build script. GitHub-hosted macos-* images ship cmake; the
// self-hosted `burnbar-swift` fleet does not, and runners started from launchd
// frequently do not inherit Homebrew's bin directory either. When cmake is
// absent the failure surfaces deep inside cargo as:
//
//     failed to execute command: No such file or directory (os error 2)
//     is `cmake` not installed?
//
// buried under ~40 lines of cargo env echo, so it reads as a Rust problem.
// Because merge_group routes native jobs to that same fleet, this blocked the
// merge queue for every PR touching native code until #1969 added
// .github/actions/ensure-libsignal-toolchain.
//
// The old shape was 21 copy-pasted "Install protobuf for libsignal Swift FFI"
// blocks that installed protoc and nothing else. This check exists because a
// 22nd variant -- codeql-pr.yml's "Install protobuf for Swift Signal FFI",
// differently named and collapsed to one line -- escaped that sweep entirely and
// was only found by auditing every `brew install` in the tree. Anyone adding a
// macOS Swift job by copying a neighbour would reintroduce the same gap, and it
// would surface only as a confusing cargo panic on one half of the fleet. So:
//
//   1. every job that triggers a libsignal FFI build must use the action, and
//   2. nobody may hand-roll a protobuf-only preflight again.
//
// Exit 0 = clean, 1 = violation. Pure Node, no dependencies.

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const WORKFLOW_DIR = ".github/workflows";
const ACTION = "ensure-libsignal-toolchain";

// Entry points that end up building the Signal FFI (directly, or via a script
// that prepares it before running Swift tests).
//
// prepare-signal-ffi-xcframework.sh is on this list deliberately: codeql-pr.yml
// and app-pr-gate.yml drive the FFI build through the `prepare` wrapper rather
// than build-signal-ffi-xcframework.sh, so leaving it out let those jobs drop
// the preflight without this gate noticing.
const FFI_BUILD_SCRIPTS = [
  "build-signal-ffi-xcframework.sh",
  "prepare-signal-ffi-xcframework.sh",
  "test-openburnbar-swift.sh",
  "test-openburnbar-mobile.sh",
  "headless-app-build.sh",
];

/**
 * Return the `jobs:` region of a workflow, split per job.
 * Restricting to `jobs:` matters: these script filenames also appear in
 * `on.*.paths` filters, and treating those as builds produced six false
 * positives on the real tree.
 */
function jobsOf(source) {
  const lines = source.split("\n");
  const start = lines.findIndex((l) => /^jobs:\s*$/.test(l));
  if (start === -1) return [];
  const body = [];
  for (let i = start + 1; i < lines.length; i += 1) {
    if (/^[A-Za-z_][A-Za-z0-9_-]*:/.test(lines[i])) break; // next top-level key
    body.push(lines[i]);
  }
  const jobs = [];
  let current = null;
  for (const line of body) {
    const header = line.match(/^ {2}([A-Za-z0-9_-]+):\s*$/);
    if (header) {
      current = { name: header[1], lines: [] };
      jobs.push(current);
      continue;
    }
    if (current) current.lines.push(line);
  }
  return jobs.map((j) => ({ name: j.name, lines: j.lines }));
}

const problems = [];
let checked = 0;

const files = readdirSync(WORKFLOW_DIR)
  .filter((f) => f.endsWith(".yml") || f.endsWith(".yaml"))
  .sort();

for (const file of files) {
  const path = join(WORKFLOW_DIR, file);
  const source = readFileSync(path, "utf8");

  for (const job of jobsOf(source)) {
    const text = job.lines.join("\n");

    // Rule 2: no hand-rolled protobuf-only preflight, anywhere.
    if (/brew install protobuf/.test(text) && !text.includes(ACTION)) {
      problems.push(
        `${path} job "${job.name}": installs protobuf by hand without ${ACTION}. ` +
          `That is the pre-#1969 shape that omitted cmake and broke the merge queue. ` +
          `Use "uses: ./.github/actions/${ACTION}" instead.`,
      );
    }

    // Only count an *invocation*. These filenames also appear in hashFiles(...)
    // cache keys; treating a cache key as the build step made an earlier draft
    // of the ordering check fire on eight correctly-ordered jobs.
    const invocationLines = [];
    job.lines.forEach((line, i) => {
      const code = line.replace(/#.*$/, "");
      if (code.includes("hashFiles(")) return;
      if (!FFI_BUILD_SCRIPTS.some((s) => code.includes(s))) return;
      if (/(^|[\s|&;("'])(\.\/|bash\s+|sh\s+|source\s+)?scripts\//.test(code)) {
        invocationLines.push(i);
      }
    });
    if (invocationLines.length === 0) continue;

    const triggers = FFI_BUILD_SCRIPTS.filter((s) =>
      invocationLines.some((i) => job.lines[i].includes(s)),
    );
    checked += 1;

    const actionLine = job.lines.findIndex((l) => l.includes(ACTION));
    if (actionLine === -1) {
      problems.push(
        `${path} job "${job.name}": builds the libsignal Signal FFI (${triggers.join(", ")}) ` +
          `but never uses ./.github/actions/${ACTION}. On the self-hosted burnbar-swift ` +
          `fleet this fails inside boring-sys with "is \`cmake\` not installed?".`,
      );
      continue;
    }

    // Ordering matters: the preflight has to run before the build consumes it.
    const firstBuild = Math.min(...invocationLines);
    if (actionLine > firstBuild) {
      problems.push(
        `${path} job "${job.name}": uses ${ACTION} but only AFTER the FFI build step ` +
          `(preflight at job line ${actionLine + 1}, first build at ${firstBuild + 1}). ` +
          `Move the preflight above the first build.`,
      );
    }
  }
}

if (checked === 0) {
  problems.push(
    `No job in ${WORKFLOW_DIR} appears to build the Signal FFI. Either the entry-point ` +
      `script names in FFI_BUILD_SCRIPTS moved, or this check has gone blind -- fix the list.`,
  );
}

if (problems.length) {
  console.error("FAIL: libsignal native toolchain preflight\n");
  for (const p of problems) console.error(`  - ${p}\n`);
  process.exit(1);
}

console.log(
  `OK: all ${checked} jobs that build the libsignal Signal FFI run ` +
    `./.github/actions/${ACTION} before the build, and no job hand-rolls a protobuf-only preflight.`,
);
