import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import assert from "node:assert/strict";
import {
  EXPECTED_MERGED_FILES,
  validatePackage,
} from "../verify-merged-audit-package.mjs";

function makeRepoFixture() {
  const root = mkdtempSync(join(tmpdir(), "obb-audit-package-"));
  mkdirSync(join(root, "security-audit/merged"), { recursive: true });
  mkdirSync(join(root, "security/threat-model"), { recursive: true });
  writeFileSync(
    join(root, "security/threat-model/README.md"),
    "SUPERSEDED BY POST-REMEDIATION SYNTHESIS\n",
  );
  for (const file of EXPECTED_MERGED_FILES) {
    writeFileSync(join(root, "security-audit/merged", file), `# ${file}\n`);
  }
  writeFileSync(
    join(root, "security-audit/merged/01_deduped_findings.jsonl"),
    [
      JSON.stringify({
        id: "M-040",
        title: "Trusted agent grants disabled concrete action gates and inherited ambient secrets",
        status: "confirmed",
        code_evidence_supports: "trusted shell approval gap plus ambient environment inheritance",
      }),
      JSON.stringify({
        id: "FP-01",
        title: "Broad YOLO no-auth claim",
        status: "false positive",
      }),
    ].join("\n") + "\n",
  );
  writeFileSync(
    join(root, "security-audit/merged/FINAL_REPORT.md"),
    [
      "## 1. Executive Summary",
      "M-040",
      "## 7. Release Blockers",
      "## 8. Regression Test Plan",
      "",
    ].join("\n"),
  );
  return root;
}

test("accepts the canonical merged audit package contract", () => {
  const repoRoot = makeRepoFixture();
  const result = validatePackage({ repoRoot, sourceRoots: [] });
  assert.equal(result.ok, true, result.errors.join("\n"));
});

test("rejects unexpected top-level files in security-audit/merged", () => {
  const repoRoot = makeRepoFixture();
  writeFileSync(join(repoRoot, "security-audit/merged/RUTHLESS_AUDIT_verdicts.txt"), "scratch\n");
  const result = validatePackage({ repoRoot, sourceRoots: [] });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /unexpected top-level merged report file/);
});

test("rejects malformed or duplicate finding IDs", () => {
  const repoRoot = makeRepoFixture();
  writeFileSync(
    join(repoRoot, "security-audit/merged/01_deduped_findings.jsonl"),
    [
      JSON.stringify({ id: "M-040", title: "one", status: "confirmed", note: "trusted ambient shell approval" }),
      JSON.stringify({ id: "M-040", title: "two", status: "confirmed", note: "trusted ambient shell approval" }),
      "{not-json}",
    ].join("\n") + "\n",
  );
  const result = validatePackage({ repoRoot, sourceRoots: [] });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /duplicate finding id: M-040/);
  assert.match(result.errors.join("\n"), /invalid JSONL at line 3/);
});

test("rejects dangerous CLI bypass flags in production source roots", () => {
  const repoRoot = makeRepoFixture();
  mkdirSync(join(repoRoot, "AgentLens/Services/CLIBridge"), { recursive: true });
  writeFileSync(
    join(repoRoot, "AgentLens/Services/CLIBridge/Bad.swift"),
    "let flag = \"--dangerously-skip-permissions\"\n",
  );
  const result = validatePackage({ repoRoot, sourceRoots: ["AgentLens"] });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /dangerous CLI bypass flags remain/);
});
