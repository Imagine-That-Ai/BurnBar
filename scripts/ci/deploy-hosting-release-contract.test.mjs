#!/usr/bin/env node
/**
 * Focused regression contract for deploy-hosting.yml:
 *
 * 1. Main path omits all --expected-release-* flags (no empty values).
 * 2. Stable tag/rollback path includes complete non-empty release coordinates.
 * 3. The staged Console profile is verified against CANDIDATE_COMMIT, not
 *    RELEASE_COMMIT, while release commit/version/tag are preserved separately.
 * 4. Every transitive helper imported by the immutable Hosting deploy and
 *    replay verifier is staged under the artifact root (helper closure).
 */

import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(SCRIPT_DIR, "..", "..");
const WORKFLOW_PATH = join(
  REPO_ROOT,
  ".github",
  "workflows",
  "deploy-hosting.yml",
);
const WORKFLOW = readFileSync(WORKFLOW_PATH, "utf8");

// ── Helpers ──────────────────────────────────────────────────────────────

/**
 * Extract a named step block from the workflow source. Returns the raw text
 * from the step name line through the next step or job at the same indent.
 */
function stepBlock(source, stepName) {
  const needle = `      - name: ${stepName}`;
  const start = source.indexOf(needle);
  if (start < 0) return null;
  // Find the end: the next "      - name:" or "  [job]" at column 2
  const rest = source.slice(start + needle.length);
  const nextStep = rest.search(/\n      - name: /);
  const nextJob = rest.search(/\n  [a-z]/);
  const ends = [nextStep, nextJob].filter((i) => i >= 0);
  const endRel = ends.length > 0 ? Math.min(...ends) : rest.length;
  return source.slice(start, start + needle.length + endRel);
}

function jobBlock(source, jobName) {
  const needle = `  ${jobName}:`;
  const start = source.indexOf(needle);
  if (start < 0) return null;
  const rest = source.slice(start + needle.length);
  const nextJob = rest.search(/\n  [a-zA-Z0-9_-]+:/u);
  const endRel = nextJob >= 0 ? nextJob : rest.length;
  return source.slice(start, start + needle.length + endRel);
}

// ── Tests ────────────────────────────────────────────────────────────────

test("push deploys are enabled while manual dry-runs remain build-only", () => {
  const build = jobBlock(WORKFLOW, "build-hosting-artifacts");
  const deploy = jobBlock(WORKFLOW, "deploy-hosting");
  const smoke = jobBlock(WORKFLOW, "hosting-smoke-result");
  assert.ok(build);
  assert.ok(deploy);
  assert.ok(smoke);

  assert.match(
    build,
    /if: \$\{\{ github\.event_name == 'workflow_dispatch' && inputs\.dry_run == true \}\}/u,
    "dry-run summary must be manual-dispatch-only",
  );
  assert.match(
    deploy,
    /if: >-\n\s+\$\{\{ !cancelled\(\)\n\s+&& needs\.build-hosting-artifacts\.result == 'success'\n\s+&& \(github\.event_name != 'workflow_dispatch' \|\| inputs\.dry_run != true\) \}\}/u,
    "push and tag events must not depend on absent workflow_dispatch inputs, and the credentialed deploy must carry a status-check function so a skipped upstream gate job cannot propagate a skip onto it",
  );
  assert.match(
    smoke,
    /if: \$\{\{ always\(\) && \(github\.event_name != 'workflow_dispatch' \|\| inputs\.dry_run != true\) \}\}/u,
    "hosting smoke must follow the same push-safe dry-run gate",
  );
  assert.doesNotMatch(
    WORKFLOW,
    /github\.event\.inputs\.dry_run/u,
    "workflow must use the typed inputs context with an explicit event guard",
  );
});

test("workflow contains Resolve signed public domain-core profile step", () => {
  const block = stepBlock(
    WORKFLOW,
    "Resolve signed public domain-core profile",
  );
  assert.ok(block, "Resolve profile step must exist");
});

test("main path omits unconditional --expected-release-* flags", () => {
  const block = stepBlock(
    WORKFLOW,
    "Resolve signed public domain-core profile",
  );
  assert.ok(block);
  // The old pattern passed --expected-release-* unconditionally with empty
  // values on main. The new pattern must NOT have unconditional flag passes.
  // Instead, release flags are guarded by `if [[ -n "$RELEASE_TAG" ]]`.
  const lines = block.split("\n");
  let inConditional = false;
  for (const line of lines) {
    if (line.includes('if [[ -n "$RELEASE_TAG" ]]')) {
      inConditional = true;
      continue;
    }
    if (inConditional && /^\s*fi\s*$/u.test(line)) {
      inConditional = false;
      continue;
    }
    if (!inConditional) {
      assert.doesNotMatch(
        line,
        /--expected-release-commit/,
        "no unconditional --expected-release-commit in main path",
      );
      assert.doesNotMatch(
        line,
        /--expected-release-version/,
        "no unconditional --expected-release-version in main path",
      );
      assert.doesNotMatch(
        line,
        /--expected-release-tag/,
        "no unconditional --expected-release-tag in main path",
      );
    }
  }
  // Verify the conditional guard exists
  assert.match(
    block,
    /if \[\[ -n "\$RELEASE_TAG" \]\]; then/,
    "release flags must be conditional on non-empty RELEASE_TAG",
  );
});

test("stable path binds only the release commit inside the conditional, keeping the profile candidate-scoped", () => {
  const block = stepBlock(
    WORKFLOW,
    "Resolve signed public domain-core profile",
  );
  assert.ok(block);
  // Inside the conditional guard, only --expected-release-commit is passed so
  // the resolver re-derives activation P from release R. Version/tag must NOT
  // be passed: they would embed a `release` block into the Console profile,
  // which the candidate-only --console-dir verification then rejects. The tag
  // is bound separately by the release gate and deployment identity.
  const lines = block.split("\n");
  let inConditional = false;
  let foundCommit = false;
  for (const line of lines) {
    if (line.includes('if [[ -n "$RELEASE_TAG" ]]')) {
      inConditional = true;
      continue;
    }
    if (inConditional && /^\s*fi\s*$/u.test(line)) {
      inConditional = false;
      continue;
    }
    if (
      inConditional &&
      /--expected-release-commit\s+"\$RELEASE_COMMIT"/.test(line)
    ) {
      foundCommit = true;
    }
  }
  assert.ok(foundCommit, "stable path must include --expected-release-commit");
  assert.doesNotMatch(
    block,
    /--expected-release-version/,
    "profile resolution must not pass --expected-release-version",
  );
  assert.doesNotMatch(
    block,
    /--expected-release-tag/,
    "profile resolution must not pass --expected-release-tag",
  );
});

test("staging step verifies against CANDIDATE_COMMIT, not RELEASE_COMMIT", () => {
  const block = stepBlock(WORKFLOW, "Stage hosting deploy artifact");
  assert.ok(block);
  // The verify-domain-core-build-profile-artifact call must use
  // --expected-candidate-commit "$CANDIDATE_COMMIT"
  assert.match(
    block,
    /--expected-candidate-commit "\$CANDIDATE_COMMIT"/,
    "verify step must use CANDIDATE_COMMIT for candidate verification",
  );
  // It must NOT use --expected-candidate-commit "$RELEASE_COMMIT"
  assert.doesNotMatch(
    block,
    /--expected-candidate-commit "\$RELEASE_COMMIT"/,
    "verify step must not use RELEASE_COMMIT for candidate verification",
  );
});

test("staging step preserves RELEASE_COMMIT separately for release coordinates", () => {
  const block = stepBlock(WORKFLOW, "Stage hosting deploy artifact");
  assert.ok(block);
  // RELEASE_COMMIT is still available in the env and used for release coords
  assert.match(
    block,
    /RELEASE_COMMIT: \$\{\{ steps\.ref\.outputs\.commit \}\}/,
    "RELEASE_COMMIT must remain in the staging step env",
  );
  assert.match(
    block,
    /CANDIDATE_COMMIT: \$\{\{ steps\.activation\.outputs\.candidate_commit \|\| steps\.ref\.outputs\.commit \}\}/,
    "CANDIDATE_COMMIT must be in the staging step env (from activation or fallback to ref commit)",
  );
});

test("staging step includes conditional release flags for artifact verifier", () => {
  const block = stepBlock(WORKFLOW, "Stage hosting deploy artifact");
  assert.ok(block);
  // The verify_args array must have a conditional release-flag block
  assert.match(
    block,
    /if \[\[ -n "\$RELEASE_TAG" \]\]; then/,
    "staging verify must conditionally include release flags on stable",
  );
  // Inside the conditional, release coordinates use RELEASE_COMMIT (R),
  // not CANDIDATE_COMMIT (C)
  const lines = block.split("\n");
  let inConditional = false;
  let foundReleaseCommit = false;
  for (const line of lines) {
    if (line.includes('if [[ -n "$RELEASE_TAG" ]]')) {
      inConditional = true;
      continue;
    }
    if (inConditional && line.includes("fi")) {
      inConditional = false;
      continue;
    }
    if (inConditional) {
      if (/--expected-release-commit\s+"\$RELEASE_COMMIT"/.test(line))
        foundReleaseCommit = true;
    }
  }
  assert.ok(
    foundReleaseCommit,
    "staging verify release flags must use RELEASE_COMMIT (R), not CANDIDATE_COMMIT (C)",
  );
});

// ── Helper closure contract ──────────────────────────────────────────────

/**
 * Walks the import graph of the staged scripts and proves every local
 * (non-node:) import resolves to a file that is also staged under the
 * artifact root. This is the transitive closure proof.
 */

const STAGED_CI_SCRIPTS = [
  "scripts/ci/deploy-firebase-hosting-rest.mjs",
  "scripts/ci/create-domain-core-runtime-artifact-manifest.mjs",
  "scripts/ci/verify-existing-domain-core-deployment.mjs",
];

const STAGED_LIB_FILES = [
  "scripts/lib/atomic-regular-file.mjs",
  "scripts/lib/firebase-hosting-rest-url.mjs",
  "scripts/lib/curl-bearer.sh",
];

/**
 * Extract local (relative) import paths from a .mjs file's source.
 * Returns an array of paths relative to the repo root.
 */
function extractLocalImports(sourcePath) {
  const source = readFileSync(sourcePath, "utf8");
  const imports = [];
  // Match: from "../lib/foo.mjs" or from "./bar.mjs"
  // Match: import ... from "../lib/foo.mjs"
  const importRegex = /\bfrom\s+"(\.\.?\/[^"]+)"/g;
  let match;
  while ((match = importRegex.exec(source)) !== null) {
    imports.push(match[1]);
  }
  return imports;
}

/**
 * Resolve a relative import path from a given script's directory to a
 * repo-root-relative path.
 */
function resolveImport(scriptPath, importPath) {
  const scriptDir = dirname(scriptPath);
  return resolve("/repo", scriptDir, importPath)
    .slice("/repo".length)
    .replace(/^\//, "");
}

/**
 * Recursively collect all local transitive imports starting from a script.
 */
function collectTransitiveImports(scriptPath, visited = new Set()) {
  const resolved = scriptPath;
  if (visited.has(resolved)) return [];
  visited.add(resolved);

  const fullPath = join(REPO_ROOT, resolved);
  if (!existsSync(fullPath)) return [];

  const imports = extractLocalImports(fullPath);
  const results = [];
  for (const imp of imports) {
    const resolvedImp = resolveImport(resolved, imp);
    results.push(resolvedImp);
    results.push(...collectTransitiveImports(resolvedImp, visited));
  }
  return results;
}

test("staging step copies every transitive helper imported by staged scripts", () => {
  const block = stepBlock(WORKFLOW, "Stage hosting deploy artifact");
  assert.ok(block);

  // Collect all transitive local imports from the staged CI scripts
  const allImports = new Set();
  for (const script of STAGED_CI_SCRIPTS) {
    for (const imp of collectTransitiveImports(script)) {
      allImports.add(imp);
    }
  }

  // Every imported helper must be staged via a `cp` command in the workflow
  for (const imp of allImports) {
    // The cp command copies from repo path to artifact root
    // e.g.: cp scripts/lib/atomic-regular-file.mjs "$ARTIFACT_ROOT/scripts/lib/"
    const cpNeedle = `cp ${imp} "$ARTIFACT_ROOT/`;
    assert.ok(
      block.includes(cpNeedle),
      `staging step must copy transitive helper: ${imp}`,
    );
  }
});

test("all imported helpers actually exist in the repository", () => {
  const allImports = new Set();
  for (const script of STAGED_CI_SCRIPTS) {
    for (const imp of collectTransitiveImports(script)) {
      allImports.add(imp);
    }
  }
  for (const imp of allImports) {
    assert.ok(
      existsSync(join(REPO_ROOT, imp)),
      `imported helper must exist in repo: ${imp}`,
    );
  }
});

test("atomic-regular-file.mjs is staged (required by deploy and verify scripts)", () => {
  const block = stepBlock(WORKFLOW, "Stage hosting deploy artifact");
  assert.ok(block);
  assert.ok(
    block.includes(
      'cp scripts/lib/atomic-regular-file.mjs "$ARTIFACT_ROOT/scripts/lib/"',
    ),
    "atomic-regular-file.mjs must be staged",
  );
});

test("firebase-hosting-rest-url.mjs is staged (required by deploy script)", () => {
  const block = stepBlock(WORKFLOW, "Stage hosting deploy artifact");
  assert.ok(block);
  assert.ok(
    block.includes(
      'cp scripts/lib/firebase-hosting-rest-url.mjs "$ARTIFACT_ROOT/scripts/lib/"',
    ),
    "firebase-hosting-rest-url.mjs must be staged",
  );
});

test("curl-bearer.sh is staged (required by stable-replay step)", () => {
  const block = stepBlock(WORKFLOW, "Stage hosting deploy artifact");
  assert.ok(block);
  assert.ok(
    block.includes(
      'cp scripts/lib/curl-bearer.sh "$ARTIFACT_ROOT/scripts/lib/"',
    ),
    "curl-bearer.sh must be staged",
  );
});

test("deploy-firebase-hosting-rest.mjs imports resolve to staged helpers", () => {
  const imports = extractLocalImports(
    join(REPO_ROOT, "scripts/ci/deploy-firebase-hosting-rest.mjs"),
  );
  assert.ok(imports.length > 0, "deploy script must have local imports");
  const block = stepBlock(WORKFLOW, "Stage hosting deploy artifact");
  assert.ok(block);
  for (const imp of imports) {
    const resolved = resolveImport(
      "scripts/ci/deploy-firebase-hosting-rest.mjs",
      imp,
    );
    assert.ok(
      block.includes(`cp ${resolved} "$ARTIFACT_ROOT/`),
      `deploy script import ${resolved} must be staged`,
    );
  }
});

test("verify-existing-domain-core-deployment.mjs imports resolve to staged helpers", () => {
  const imports = extractLocalImports(
    join(REPO_ROOT, "scripts/ci/verify-existing-domain-core-deployment.mjs"),
  );
  assert.ok(imports.length > 0, "verify script must have local imports");
  const block = stepBlock(WORKFLOW, "Stage hosting deploy artifact");
  assert.ok(block);
  for (const imp of imports) {
    const resolved = resolveImport(
      "scripts/ci/verify-existing-domain-core-deployment.mjs",
      imp,
    );
    assert.ok(
      block.includes(`cp ${resolved} "$ARTIFACT_ROOT/`),
      `verify script import ${resolved} must be staged`,
    );
  }
});

test("create-domain-core-runtime-artifact-manifest.mjs has no local imports (self-contained)", () => {
  const imports = extractLocalImports(
    join(
      REPO_ROOT,
      "scripts/ci/create-domain-core-runtime-artifact-manifest.mjs",
    ),
  );
  assert.equal(
    imports.length,
    0,
    "runtime artifact manifest script should have no local imports (self-contained)",
  );
});

// ── Stable-tag replay missing-receipt guard ──────────────────────────────
//
// Regression: when a stable release exists on GitHub but its immutable Console
// deployment receipt asset is missing, the guard must fail closed (exit 1)
// only when the live deployment identity commit equals the release commit P.
// The pre-fix guard fetched the live runtime-artifact-manifest and compared
// its candidate.candidateCommit — coupling the missing-receipt decision to
// candidate C. The fix fetches the live domain-core-deployment-identity.json
// (the same v2 console identity embedded at build time) and compares its
// `.commit` to RELEASE_COMMIT (P). Candidate C stays validated independently
// via the release-gate path passed to verify-existing-domain-core-deployment.

/**
 * Extract the missing-receipt branch (the `if ! jq -e ...any(.name == $asset)...`
 * block) from the stable-replay step. Returns the raw text from the `if !` line
 * through the `mkdir "$RUNNER_TEMP/existing-console-evidence"` boundary that
 * marks the existing-receipt branch.
 */
function missingReceiptBranch(source) {
  const block = stepBlock(source, "Refuse non-identical stable-tag redeploy");
  assert.ok(block, "stable-replay step must exist");
  const start = block.indexOf('if ! jq -e --arg asset "$asset"');
  assert.ok(start >= 0, "missing-receipt branch guard must exist");
  const tail = block.slice(start);
  const end = tail.indexOf(
    '\n          mkdir "$RUNNER_TEMP/existing-console-evidence"',
  );
  return end >= 0 ? tail.slice(0, end + 1) : tail;
}

test("missing-receipt guard fetches the live deployment identity, not the runtime artifact manifest", () => {
  const branch = missingReceiptBranch(WORKFLOW);
  // The guard must read the v2 console deployment identity (commit-bearing),
  // not the runtime-artifact-manifest (candidate-bearing). The pre-fix shape
  // curled domain-core-runtime-artifact-manifest.json and read
  // .candidate.candidateCommit; the fix must not.
  assert.match(
    branch,
    /"https:\/\/app\.burnbar\.ai\/domain-core-deployment-identity\.json"/u,
    "missing-receipt guard must fetch domain-core-deployment-identity.json",
  );
  assert.doesNotMatch(
    branch,
    /domain-core-runtime-artifact-manifest\.json/u,
    "missing-receipt guard must NOT consult the runtime artifact manifest (candidate C is validated separately)",
  );
  assert.doesNotMatch(
    branch,
    /\.candidate\.candidateCommit/u,
    "missing-receipt guard must NOT read candidate.candidateCommit (candidate C is validated separately via the release gate)",
  );
});

test("missing-receipt guard validates the live identity is a v2 console identity before trusting its commit", () => {
  const branch = missingReceiptBranch(WORKFLOW);
  // The fetched identity must be schema-checked: schemaVersion 2, consumer
  // console, and a 40-hex commit string. Without this, a malformed or
  // attacker-controlled live file could spoof the fail-closed decision.
  assert.match(branch, /\.schemaVersion != 2/u);
  assert.match(branch, /\.consumer != "console"/u);
  assert.match(branch, /test\("\^\[0-9a-f\]\{40\}\$"\)/u);
});

test("missing-receipt guard fails closed when live identity commit equals RELEASE_COMMIT P", () => {
  const branch = missingReceiptBranch(WORKFLOW);
  // The fail-closed comparison binds on the release commit P (the identity's
  // `.commit`), not on candidate C.
  assert.match(
    branch,
    /live_commit="\$\(jq -er '\.commit' "\$identity"\)"/u,
    "guard must extract the live identity commit via jq .commit",
  );
  assert.match(
    branch,
    /if \[\[ "\$live_commit" == "\$RELEASE_COMMIT" \]\]/u,
    "guard must compare live identity commit to RELEASE_COMMIT (P), not CANDIDATE_COMMIT",
  );
  assert.match(branch, /exit 1/u);
  // The error message must name the deployment identity and the missing
  // receipt, so an operator can trace the fail-closed reason.
  assert.match(branch, /already live \(deployment identity commit/u);
  assert.match(branch, /immutable Console deployment receipt is missing/u);
});

test("missing-receipt guard does not consult CANDIDATE_COMMIT in the fail-closed branch", () => {
  const branch = missingReceiptBranch(WORKFLOW);
  // Candidate C is validated separately via the release-gate path passed to
  // verify-existing-domain-core-deployment; the missing-receipt branch must
  // not reference CANDIDATE_COMMIT at all.
  assert.doesNotMatch(
    branch,
    /CANDIDATE_COMMIT/u,
    "missing-receipt guard must not reference CANDIDATE_COMMIT (candidate C is validated separately)",
  );
});

test("missing-receipt guard fails closed when live identity is unreachable and proceeds only when live commit differs from P", () => {
  const branch = missingReceiptBranch(WORKFLOW);
  assert.ok(
    branch.includes(
      'echo "::error::Cannot establish the live Console release identity while the immutable deployment receipt is missing. Refusing production mutation."\n              exit 1',
    ),
    "guard must fail closed when the live identity is unreachable",
  );
  assert.ok(
    branch.includes(
      'fi\n            echo "reused=false" >> "$GITHUB_OUTPUT"\n            exit 0',
    ),
    "guard must emit reused=false and exit 0 when live commit differs from RELEASE_COMMIT",
  );
});

test("existing-receipt branch passes --release-gate to the verify-existing script", () => {
  // The existing-receipt path (receipt asset present) must pass the release
  // gate so verify-existing binds the receipt candidate to the authoritative
  // candidate C, not to the release commit P. This is the C!=P replay contract.
  const block = stepBlock(WORKFLOW, "Refuse non-identical stable-tag redeploy");
  assert.ok(block);
  assert.match(
    block,
    /node "\$ARTIFACT_ROOT\/scripts\/ci\/verify-existing-domain-core-deployment\.mjs"/u,
  );
  assert.match(
    block,
    /--release-gate "\$ARTIFACT_ROOT\/domain-core-release-inputs\/domain-core-release-gate\.json"/u,
    "existing-receipt branch must pass --release-gate so the receipt candidate binds to C, not P",
  );
});
