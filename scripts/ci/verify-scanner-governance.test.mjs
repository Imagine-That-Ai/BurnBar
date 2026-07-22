#!/usr/bin/env node
/**
 * Regression tests for P-SEC-4 scanner governance changes.
 *
 * Verifies that the gitleaks config tightening (key allowlist scoping +
 * linux hex narrowing) and CODEOWNERS governance are in place.
 * Each assertion is a meaningful regression check that would fail on the
 * pre-fix code.
 */

import { readFileSync } from "node:fs";

const gitleaksConfig = readFileSync(".gitleaks.toml", "utf8");
const codeowners = readFileSync(".github/CODEOWNERS", "utf8");
const verifierScript = readFileSync(
  "scripts/ci/verify-codeowners-security-trees.sh",
  "utf8",
);

let passed = 0;
let failed = 0;

function ok(label) {
  console.log(`  ok   ${label}`);
  passed += 1;
}

function fail(label, detail) {
  console.error(`  FAIL ${label}: ${detail}`);
  failed += 1;
}

function expectTrue(label, condition, detail) {
  if (condition) {
    ok(label);
  } else {
    fail(label, detail);
  }
}

/**
 * Split the gitleaks TOML into individual [[allowlists]] blocks.
 * Returns an array of block text strings (preamble before the first
 * [[allowlists]] header is discarded).
 */
function splitAllowlists(text) {
  const parts = text.split(/^\[\[allowlists\]\]/m);
  return parts.slice(1);
}

/**
 * Find the allowlist block whose description contains the given substring.
 */
function findAllowlistByText(text, descriptionSubstring) {
  const blocks = splitAllowlists(text);
  return blocks.find((block) => block.includes(descriptionSubstring));
}

console.log("Self-test: scanner governance (P-SEC-4)\n");

// ---------------------------------------------------------------------------
// Test A: key allowlist is Swift-scoped
// ---------------------------------------------------------------------------
{
  const label = "A: key allowlist is Swift-scoped";
  const block = findAllowlistByText(
    gitleaksConfig,
    "Swift key-material parameter labels",
  );
  if (!block) {
    fail(
      label,
      "allowlist with description 'Swift key-material parameter labels' not found",
    );
  } else {
    // Assert condition = "AND" (explicitly, even though the boundary verifier
    // also checks this — clarity for the governance regression).
    expectTrue(
      `${label} — condition is AND`,
      /condition\s*=\s*"AND"/.test(block),
      'expected condition = "AND" in the key allowlist block',
    );

    // Extract the paths array from the block.
    const pathsMatch = block.match(/paths\s*=\s*\[([\s\S]*?)\]/);
    if (!pathsMatch) {
      fail(
        `${label} — paths array exists`,
        "paths array is missing (was globally unscoped before fix)",
      );
    } else {
      const pathsContent = pathsMatch[1];
      // Extract individual path entries from triple-quoted strings.
      const pathEntries = [...pathsContent.matchAll(/'''([^']+)'''/g)].map(
        (m) => m[1],
      );

      // paths array is not empty (was empty/missing before the fix).
      expectTrue(
        `${label} — paths array is non-empty`,
        pathEntries.length > 0,
        "paths array is empty",
      );

      // includes at least AgentLens/.*\.swift.
      expectTrue(
        `${label} — paths includes AgentLens Swift pattern`,
        pathEntries.some((p) => p.includes("AgentLens/.*\\.swift")),
        "paths does not include 'AgentLens/.*\\.swift'",
      );

      // no non-Swift path patterns — every path must reference .swift files
      // so the global pattern cannot mask a leaked key literal in other
      // languages (TS/Python/Kotlin/etc.).
      const nonSwiftPaths = pathEntries.filter((p) => !p.includes(".swift"));
      expectTrue(
        `${label} — all paths are Swift-scoped`,
        nonSwiftPaths.length === 0,
        `non-Swift path patterns found: ${nonSwiftPaths.join(", ")}`,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Test B: linux evidence hex allowlist is narrowed
// ---------------------------------------------------------------------------
{
  const label = "B: linux evidence hex allowlist is narrowed";
  const block = findAllowlistByText(
    gitleaksConfig,
    "Linux-port evidence transcripts",
  );
  if (!block) {
    fail(
      label,
      "allowlist with description 'Linux-port evidence transcripts' not found",
    );
  } else {
    // Must NOT contain the broad pattern [0-9a-f]{24,64} (the old overly-broad
    // pattern that would mask any 24–64 hex char string).
    expectTrue(
      `${label} — no broad [0-9a-f]{24,64} pattern`,
      !block.includes("[0-9a-f]{24,64}"),
      "block still contains the overly-broad [0-9a-f]{24,64} pattern",
    );

    // Must contain a 64-char hex pattern (sha256 digests).
    expectTrue(
      `${label} — contains 64-hex (sha256) pattern`,
      block.includes("[0-9a-f]{64}"),
      "block does not contain [0-9a-f]{64} pattern for sha256 digests",
    );

    // Must contain a 40-char hex pattern (git commit SHAs).
    expectTrue(
      `${label} — contains 40-hex (commit SHA) pattern`,
      block.includes("[0-9a-f]{40}"),
      "block does not contain [0-9a-f]{40} pattern for git commit SHAs",
    );
  }
}

// ---------------------------------------------------------------------------
// Test C: CODEOWNERS has gitleaks entries
// ---------------------------------------------------------------------------
{
  const label = "C: CODEOWNERS has gitleaks entries";
  const lines = codeowners.split("\n");

  expectTrue(
    `${label} — .gitleaks.toml rule present`,
    lines.some((line) => /^\.gitleaks\.toml\s/.test(line)),
    "CODEOWNERS does not contain a line starting with '.gitleaks.toml '",
  );

  expectTrue(
    `${label} — .gitleaksignore rule present`,
    lines.some((line) => /^\.gitleaksignore\s/.test(line)),
    "CODEOWNERS does not contain a line starting with '.gitleaksignore '",
  );
}

// ---------------------------------------------------------------------------
// Test D: CODEOWNERS verifier requires gitleaks files
// ---------------------------------------------------------------------------
{
  const label = "D: CODEOWNERS verifier requires gitleaks files";

  // Extract the REQUIRED_RULES list from the embedded Python in the verifier
  // script and check that both gitleaks files are listed.
  const requiredRulesMatch = verifierScript.match(
    /REQUIRED_RULES\s*=\s*\[([\s\S]*?)\]/,
  );
  const requiredRules = requiredRulesMatch ? requiredRulesMatch[1] : "";

  expectTrue(
    `${label} — REQUIRED_RULES includes .gitleaks.toml`,
    requiredRules.includes('".gitleaks.toml"'),
    "verifier script does not list '.gitleaks.toml' in REQUIRED_RULES",
  );

  expectTrue(
    `${label} — REQUIRED_RULES includes .gitleaksignore`,
    requiredRules.includes('".gitleaksignore"'),
    "verifier script does not list '.gitleaksignore' in REQUIRED_RULES",
  );

  // Also check EXPECTED_FINAL_RULES so that final-match coverage is enforced.
  const expectedFinalMatch = verifierScript.match(
    /EXPECTED_FINAL_RULES\s*=\s*\{([\s\S]*?)\}/,
  );
  const expectedFinal = expectedFinalMatch ? expectedFinalMatch[1] : "";

  expectTrue(
    `${label} — EXPECTED_FINAL_RULES includes .gitleaks.toml`,
    expectedFinal.includes('".gitleaks.toml": ".gitleaks.toml"'),
    "verifier script does not map '.gitleaks.toml' in EXPECTED_FINAL_RULES",
  );

  expectTrue(
    `${label} — EXPECTED_FINAL_RULES includes .gitleaksignore`,
    expectedFinal.includes('".gitleaksignore": ".gitleaksignore"'),
    "verifier script does not map '.gitleaksignore' in EXPECTED_FINAL_RULES",
  );
}

console.log(`\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);