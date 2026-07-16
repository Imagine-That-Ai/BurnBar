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

// ── Tests ────────────────────────────────────────────────────────────────

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

test("stable path includes complete non-empty release coordinates inside conditional", () => {
  const block = stepBlock(
    WORKFLOW,
    "Resolve signed public domain-core profile",
  );
  assert.ok(block);
  // Inside the conditional guard, all three release flags must be present
  // with non-empty variable references (not literal empty strings).
  const lines = block.split("\n");
  let inConditional = false;
  let foundCommit = false;
  let foundVersion = false;
  let foundTag = false;
  for (const line of lines) {
    if (line.includes('if [[ -n "$RELEASE_TAG" ]]')) {
      inConditional = true;
      continue;
    }
    if (inConditional && /^\s*fi\s*$/u.test(line)) {
      inConditional = false;
      continue;
    }
    if (inConditional) {
      if (/--expected-release-commit\s+"\$RELEASE_COMMIT"/.test(line))
        foundCommit = true;
      if (/--expected-release-version\s+"\$\{RELEASE_TAG#v\}"/.test(line))
        foundVersion = true;
      if (/--expected-release-tag\s+"\$RELEASE_TAG"/.test(line))
        foundTag = true;
    }
  }
  assert.ok(foundCommit, "stable path must include --expected-release-commit");
  assert.ok(
    foundVersion,
    "stable path must include --expected-release-version",
  );
  assert.ok(foundTag, "stable path must include --expected-release-tag");
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
