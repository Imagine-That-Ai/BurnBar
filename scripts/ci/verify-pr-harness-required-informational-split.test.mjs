#!/usr/bin/env node
/**
 * Regression test for the P-QA-1 required/informational aggregate split and
 * emulator runner fix in .github/workflows/openburnbar-pr-harness.yml.
 *
 * Validates:
 *   1. harness-required exists, has if: always(), has needs, and its needs list
 *      exactly matches the deterministic gate set.
 *   2. harness-informational exists, has if: always(), has needs, and its needs
 *      list includes all external/emulator/virtualization jobs.
 *   3. Every non-aggregate, non-utility job appears in at least one aggregate
 *      needs list (harness-required, harness-informational,
 *      platform-confidence-gate, or targeted-e2e-gate) — no coverage dropped.
 *   4. android-hermes-smoke uses runs-on: ubuntu-24.04 and arch: x86_64
 *      (not macos-26 or arm64-v8a) and has a KVM enable step.
 *   5. macos-26 jobs wait for platform-misc (fail-fast: no hosted-macOS burn
 *      after a red classifier). ios-mobile stays informational and is capped
 *      at 30-45 minutes. app-xctest stays required at 75 minutes and is not
 *      continue-on-error (timeout stays honest-red).
 *
 * Run: node scripts/ci/verify-pr-harness-required-informational-split.test.mjs
 * Exits 0 on pass, 1 on fail.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT =
  process.env.PR_HARNESS_REQUIRED_INFO_SPLIT_ROOT ??
  join(SCRIPT_DIR, "..", "..");
const WORKFLOW = join(
  REPO_ROOT,
  ".github",
  "workflows",
  "openburnbar-pr-harness.yml",
);

const REQUIRED_JOBS = [
  "platform-misc",
  "functions-integration",
  "windows",
  "swift-core",
  "app-xctest",
  "supply-chain",
];

const INFORMATIONAL_JOBS = [
  "android",
  "node-evals",
  "ios-mobile",
  "retrieval-evals",
  "hermes-gateway-e2ee-proof",
  "hermes-iroh-e2e",
  "android-hermes-smoke",
  "computer-use-e2e",
  "mercury-media-e2e",
];

// Jobs that are aggregates or utility fan-out, not test jobs — excluded from the
// "every job is covered by an aggregate" invariant.
const NON_TEST_JOBS = new Set([
  "harness-required",
  "harness-informational",
  "platform-confidence-gate",
  "targeted-e2e-gate",
  "openburnbar-pr",
  "path-filter",
]);

const AGGREGATE_JOBS = [
  "harness-required",
  "harness-informational",
  "platform-confidence-gate",
  "targeted-e2e-gate",
];

let passed = 0;
let failed = 0;
const failures = [];

function expect(label, condition, detail = "") {
  if (condition) {
    console.log(`  PASS ${label}`);
    passed += 1;
  } else {
    console.error(`  FAIL ${label}${detail ? `: ${detail}` : ""}`);
    failures.push(`${label}${detail ? `: ${detail}` : ""}`);
    failed += 1;
  }
}

/**
 * Extract top-level job blocks from the workflow YAML.
 * Matches `^  ([A-Za-z0-9_-]+):\s*$` at 2-space indent inside the `jobs:` map,
 * exactly like verify-pr-harness-aggregate-gates.mjs::extractJobs.
 */
function extractJobs(source) {
  const jobs = new Map();
  const lines = source.split("\n");
  let inJobs = false;
  let currentName = null;
  let currentLines = [];

  for (const line of lines) {
    if (!inJobs) {
      if (line === "jobs:") inJobs = true;
      continue;
    }

    const match = /^  ([A-Za-z0-9_-]+):\s*$/u.exec(line);
    if (match) {
      if (currentName) jobs.set(currentName, currentLines.join("\n"));
      currentName = match[1];
      currentLines = [line];
      continue;
    }

    if (currentName) currentLines.push(line);
  }

  if (currentName) jobs.set(currentName, currentLines.join("\n"));
  return jobs;
}

/**
 * Extract the `needs:` list from a job block.
 * Looks for the `needs:` key (4-space indent) and collects list items
 * matching `^      - ([A-Za-z0-9_-]+)\s*$` until a non-list line at <= 4-space
 * indent.
 */
function extractNeeds(block) {
  const lines = block.split("\n");
  const needs = [];
  let inNeeds = false;

  for (const line of lines) {
    if (!inNeeds) {
      if (/^    needs:\s*$/u.test(line)) {
        inNeeds = true;
      } else if (/^    needs:\s*\[(.+)\]\s*$/u.test(line)) {
        // Inline array form: needs: [a, b, c]
        const match = /^    needs:\s*\[(.+)\]\s*$/u.exec(line);
        for (const item of match[1].split(",")) {
          const trimmed = item.trim();
          if (trimmed) needs.push(trimmed);
        }
        break;
      }
      continue;
    }

    const itemMatch = /^      - ([A-Za-z0-9_-]+)\s*$/u.exec(line);
    if (itemMatch) {
      needs.push(itemMatch[1]);
      continue;
    }

    // If we hit a line that's not a list item while in the needs section, check
    // if it's still part of the needs block (indented under needs) or a new key.
    if (/^    [A-Za-z0-9_-]+:/.test(line) || /^  [A-Za-z0-9_-]+:\s*$/.test(line) || line.trim() === "") {
      // An empty line might separate sections; a new key at 4-space indent ends needs.
      if (line.trim() === "") continue;
      break;
    }
  }

  return needs;
}

function normalizeIf(raw) {
  return raw
    .trim()
    .replace(/^\$\{\{\s*/u, "")
    .replace(/\s*\}\}$/u, "")
    .trim();
}

function jobIf(block) {
  const match = /^    if:\s*(.+)$/mu.exec(block);
  return match ? normalizeIf(match[1]) : "";
}

function hasNeeds(block) {
  return /^    needs:/mu.test(block);
}


// ---------------------------------------------------------------------------
// Run tests
// ---------------------------------------------------------------------------

console.log("Regression test: P-QA-1 required/informational split\n");

if (!existsSync(WORKFLOW)) {
  console.error(`FAIL: missing workflow: ${WORKFLOW}`);
  process.exit(1);
}

const source = readFileSync(WORKFLOW, "utf8");
const jobs = extractJobs(source);
const allJobNames = [...jobs.keys()];

// --- Windows native domain-core prerequisite ---
{
  const block = jobs.get("windows");

  expect("windows job exists", block !== undefined);

  if (block) {
    const nativeBuildIndex = block.indexOf(
      "cargo build --manifest-path crates/openburnbar-domain-core/Cargo.toml -p openburnbar-domain-ffi",
    );
    const solutionBuildIndex = block.indexOf(
      "dotnet build windows/OpenBurnBar.sln",
    );

    expect(
      "windows job installs the pinned Rust toolchain",
      block.includes("dtolnay/rust-toolchain@b3b07ba8b418998c39fb20f53e8b695cdcc8de1b"),
    );
    expect(
      "windows job builds openburnbar-domain-ffi before the C# solution",
      nativeBuildIndex !== -1 &&
        solutionBuildIndex !== -1 &&
        nativeBuildIndex < solutionBuildIndex,
    );
    expect(
      "windows test suite requires the native domain core",
      block.includes('OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE: "1"'),
    );
  }
}

// --- Assertion 1: harness-required ---
{
  const name = "harness-required";
  const block = jobs.get(name);

  expect(`${name} job exists`, block !== undefined);

  if (block) {
    const condition = jobIf(block);
    expect(
      `${name} has if: always()`,
      condition === "always()",
      `found: ${condition}`,
    );

    expect(`${name} has needs`, hasNeeds(block));

    const needs = extractNeeds(block);
    const requiredSet = new Set(REQUIRED_JOBS);
    const needsSet = new Set(needs);

    expect(
      `${name} needs list is non-empty`,
      needs.length > 0,
    );

    expect(
      `${name} needs exactly matches required set (no extra, no missing)`,
      needs.length === REQUIRED_JOBS.length &&
        needs.every((n) => requiredSet.has(n)) &&
        REQUIRED_JOBS.every((n) => needsSet.has(n)),
      `expected [${REQUIRED_JOBS.join(", ")}], got [${needs.join(", ")}]`,
    );
  }
}

// --- Assertion 2: harness-informational ---
{
  const name = "harness-informational";
  const block = jobs.get(name);

  expect(`${name} job exists`, block !== undefined);

  if (block) {
    const condition = jobIf(block);
    expect(
      `${name} has if: always()`,
      condition === "always()",
      `found: ${condition}`,
    );

    expect(`${name} has needs`, hasNeeds(block));

    const needs = extractNeeds(block);
    const needsSet = new Set(needs);
    const missing = INFORMATIONAL_JOBS.filter((n) => !needsSet.has(n));

    expect(
      `${name} needs list is non-empty`,
      needs.length > 0,
    );

    expect(
      `${name} needs includes all informational jobs`,
      missing.length === 0,
      `missing: [${missing.join(", ")}]`,
    );
  }
}

// --- Assertion 3: no coverage dropped ---
{
  // Collect all jobs referenced across all aggregate needs lists.
  const allCovered = new Set();

  for (const aggName of AGGREGATE_JOBS) {
    const block = jobs.get(aggName);
    if (block) {
      for (const n of extractNeeds(block)) {
        allCovered.add(n);
      }
    }
  }

  // Every non-aggregate, non-utility job must appear in at least one aggregate.
  const uncovered = allJobNames.filter(
    (name) => !NON_TEST_JOBS.has(name) && !allCovered.has(name),
  );

  expect(
    "every test job appears in at least one aggregate needs list (no coverage dropped)",
    uncovered.length === 0,
    `uncovered jobs: [${uncovered.join(", ")}]`,
  );
}

// --- Assertion 4: android-hermes-smoke emulator fix ---
{
  const name = "android-hermes-smoke";
  const block = jobs.get(name);

  expect(`${name} job exists`, block !== undefined);

  if (block) {
    const runsOnMatch = /^    runs-on:\s*(.+)$/mu.exec(block);
    const runsOn = runsOnMatch ? runsOnMatch[1].trim() : "";

    expect(
      `${name} runs-on ubuntu-24.04`,
      runsOn === "ubuntu-24.04",
      `found runs-on: ${runsOn}`,
    );

    expect(
      `${name} does NOT run on macos-26`,
      !/^    runs-on:\s*macos-26/mu.test(block),
      "found runs-on: macos-26",
    );

    // Check the emulator-runner step for arch: x86_64.
    // The emulator-runner is a `uses:` step; the `arch:` field sits inside its
    // `with:` block. We look for `arch: x86_64` in a real YAML field (not a
    // comment) and verify arm64-v8a is absent from actual arch: values.
    expect(
      `${name} uses arch: x86_64 in emulator-runner`,
      /^          arch:\s*x86_64\s*$/mu.test(block),
      "arch: x86_64 not found in emulator-runner with block",
    );

    expect(
      `${name} does NOT use arch: arm64-v8a`,
      !/^          arch:\s*arm64-v8a/mu.test(block),
      "found arch: arm64-v8a in emulator-runner with block",
    );


    // KVM enable step — follows the domain-core.yml pattern.
    expect(
      `${name} has a KVM enable step`,
      /KVM/u.test(block),
      "no KVM reference found in job block",
    );
  }
}

// --- Assertion 5: fail-fast + informational iOS cap + required XCTest timeout ---
{
  const macosJobs = [];
  for (const [name, block] of jobs) {
    if (/^    runs-on:\s*macos-26\s*$/mu.test(block)) {
      macosJobs.push(name);
    }
  }

  expect("at least one macos-26 job exists", macosJobs.length > 0);

  for (const name of macosJobs) {
    const needs = extractNeeds(jobs.get(name));
    expect(
      `${name} waits for platform-misc (fail-fast: no macos-26 burn after red classifier)`,
      needs.includes("platform-misc"),
      `needs: [${needs.join(", ")}]`,
    );
  }

  const ios = jobs.get("ios-mobile");
  expect("ios-mobile job exists", ios !== undefined);
  if (ios) {
    const timeoutMatch = /^    timeout-minutes:\s*(\d+)\s*$/mu.exec(ios);
    const timeout = timeoutMatch ? Number(timeoutMatch[1]) : NaN;
    expect(
      "ios-mobile timeout is 30-45 minutes (informational must not hold macos-26 all night)",
      timeout >= 30 && timeout <= 45,
      `found timeout-minutes: ${timeoutMatch ? timeoutMatch[1] : "(missing)"}`,
    );
    expect(
      "ios-mobile job is not continue-on-error (timeout stays visible, not skip/success)",
      !/^    continue-on-error:/mu.test(ios),
    );
  }

  const app = jobs.get("app-xctest");
  expect("app-xctest job exists", app !== undefined);
  if (app) {
    const timeoutMatch = /^    timeout-minutes:\s*(\d+)\s*$/mu.exec(app);
    const timeout = timeoutMatch ? Number(timeoutMatch[1]) : NaN;
    expect(
      "app-xctest keeps the required 75-minute red timeout (do not shrink away XCTest evidence)",
      timeout === 75,
      `found timeout-minutes: ${timeoutMatch ? timeoutMatch[1] : "(missing)"}`,
    );
    expect(
      "app-xctest job is not continue-on-error (timeout stays honest-red)",
      !/^    continue-on-error:/mu.test(app),
    );
  }

  const platformMisc = jobs.get("platform-misc");
  expect("platform-misc job exists", platformMisc !== undefined);
  if (platformMisc) {
    expect(
      "platform-misc still runs the app-test log classifier (do not delete or skip the honest-red step)",
      /Test OpenBurnBar app-test log classifier/u.test(platformMisc),
    );
    const classifierIdx = platformMisc.indexOf("Test OpenBurnBar app-test log classifier");
    const classifierTail = platformMisc.slice(classifierIdx);
    const nextStep = classifierTail.search(/\n      - (?:name:|uses:)/u);
    const classifierStep = nextStep === -1 ? classifierTail : classifierTail.slice(0, nextStep);
    expect(
      "classifier step is not continue-on-error (stay honest-red)",
      !/continue-on-error:/u.test(classifierStep),
    );
  }
}


// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

if (failed > 0) {
  console.error(
    `\nFAIL: ${failed} P-QA-1 required/informational split test case(s) failed.`,
  );
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log(
  `\nPASS: ${passed} P-QA-1 required/informational split test case(s) passed.`,
);
