import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  analyzePullRequest,
  classify,
  DEFAULT_SUPERSEDED_THRESHOLD,
  fileOnRef,
  formatReport,
  isSignificantLine,
  parseUnifiedDiff,
  scoreFile,
  VERDICTS,
} from "./find-superseded-prs.mjs";

// ── significance filter ────────────────────────────────────────────────────
// This filter is what stops every PR from scoring as superseded, so it carries
// the most tests.

test("structural noise is not significant", () => {
  for (const line of ["", "   ", "}", "  });", "\t}", "]", "  )", "{", "-->"]) {
    assert.equal(isSignificantLine(line), false, JSON.stringify(line));
  }
});

test("real source lines are significant", () => {
  for (const line of [
    "  const walkthrough = MemoryMCPWalkthroughView()",
    "import assert from \"node:assert/strict\";",
    "// Keep the deep-link container above the ScrollView",
  ]) {
    assert.equal(isSignificantLine(line), true, line);
  }
});

test("a short identifier line is below the length floor", () => {
  assert.equal(isSignificantLine("let x=1"), false);
  assert.equal(isSignificantLine("let value = 1"), true);
});

// ── diff parsing ───────────────────────────────────────────────────────────

test("added lines are collected per file and headers excluded", () => {
  const diff = [
    "diff --git a/src/a.swift b/src/a.swift",
    "index 111..222 100644",
    "--- a/src/a.swift",
    "+++ b/src/a.swift",
    "@@ -1,2 +1,3 @@",
    " context line here",
    "+let addedValue = compute()",
    "-let removedValue = old()",
    "diff --git a/src/b.swift b/src/b.swift",
    "--- /dev/null",
    "+++ b/src/b.swift",
    "@@ -0,0 +1 @@",
    "+let secondFile = true",
  ].join("\n");

  const files = parseUnifiedDiff(diff);
  assert.deepEqual([...files.keys()], ["src/a.swift", "src/b.swift"]);
  assert.deepEqual(files.get("src/a.swift").added, ["let addedValue = compute()"]);
  assert.deepEqual(files.get("src/b.swift").added, ["let secondFile = true"]);
  // The `+++ b/...` header must never be counted as content.
  for (const entry of files.values()) {
    for (const line of entry.added) assert.equal(line.startsWith("++ "), false);
  }
});

test("a rename is attributed to its post-image path", () => {
  const diff = [
    "diff --git a/old/name.mjs b/new/name.mjs",
    "similarity index 98%",
    "rename from old/name.mjs",
    "rename to new/name.mjs",
    "@@ -1 +1,2 @@",
    "+const addedAfterRename = true;",
  ].join("\n");
  const files = parseUnifiedDiff(diff);
  assert.deepEqual([...files.keys()], ["new/name.mjs"]);
});

test("binary files are flagged rather than scored", () => {
  const diff = [
    "diff --git a/assets/icon.png b/assets/icon.png",
    "Binary files a/assets/icon.png and b/assets/icon.png differ",
  ].join("\n");
  assert.equal(parseUnifiedDiff(diff).get("assets/icon.png").binary, true);
});

test("an empty diff parses to no files", () => {
  assert.equal(parseUnifiedDiff("").size, 0);
});

// ── per-file scoring ───────────────────────────────────────────────────────

test("a path absent from the base branch scores zero, never null", () => {
  const score = scoreFile({
    added: ["const brandNewThing = true;"],
    baseContent: null,
  });
  assert.equal(score.ratio, 0);
  assert.equal(score.significant, 1);
});

test("content already present on the base branch scores 1", () => {
  const score = scoreFile({
    added: ["const alreadyLanded = true;", "  const alsoLanded = 2;"],
    baseContent: "const alreadyLanded = true;\nconst alsoLanded = 2;\n",
  });
  assert.equal(score.ratio, 1);
});

test("indentation changes do not defeat matching", () => {
  const score = scoreFile({
    added: ["        const deeplyIndented = true;"],
    baseContent: "const deeplyIndented = true;\n",
  });
  assert.equal(score.ratio, 1);
});

test("a diff of only structural noise yields a null ratio", () => {
  const score = scoreFile({ added: ["}", "  })"], baseContent: "irrelevant" });
  assert.equal(score.significant, 0);
  assert.equal(score.ratio, null);
});

// ── classification ─────────────────────────────────────────────────────────

test("full coverage is superseded", () => {
  const result = classify([{ significant: 100, present: 100 }]);
  assert.equal(result.verdict, VERDICTS.SUPERSEDED);
  assert.equal(result.coverage, 1);
});

test("no coverage is active", () => {
  assert.equal(classify([{ significant: 40, present: 0 }]).verdict, VERDICTS.ACTIVE);
});

test("middling coverage is partially landed", () => {
  assert.equal(classify([{ significant: 100, present: 70 }]).verdict, VERDICTS.PARTIAL);
});

test("nothing significant is indeterminate, not superseded", () => {
  // A lockfile bump or pure deletion must never be reported as already landed.
  const result = classify([{ significant: 0, present: 0 }]);
  assert.equal(result.verdict, VERDICTS.INDETERMINATE);
  assert.equal(result.coverage, null);
});

test("lines pool across files so a big file outvotes a small one", () => {
  // 600 landed implementation lines + 3 novel README lines is superseded work,
  // not active work. Averaging per-file ratios would wrongly say 50%.
  const result = classify([
    { significant: 600, present: 600 },
    { significant: 3, present: 0 },
  ]);
  assert.equal(result.verdict, VERDICTS.SUPERSEDED);
  assert.ok(result.coverage > DEFAULT_SUPERSEDED_THRESHOLD);
});

test("the superseded threshold is exclusive of near-misses", () => {
  assert.equal(classify([{ significant: 100, present: 94 }]).verdict, VERDICTS.PARTIAL);
  assert.equal(classify([{ significant: 100, present: 95 }]).verdict, VERDICTS.SUPERSEDED);
});

// ── report rendering ───────────────────────────────────────────────────────

test("the report groups by verdict and omits empty buckets", () => {
  const text = formatReport([
    { number: 2456, title: "walkthrough", verdict: VERDICTS.SUPERSEDED, coverage: 1 },
    { number: 2435, title: "ci phase 0", verdict: VERDICTS.ACTIVE, coverage: 0.1 },
  ]);
  assert.match(text, /SUPERSEDED \(1\)/u);
  assert.match(text, /ACTIVE \(1\)/u);
  assert.doesNotMatch(text, /PARTIALLY-LANDED/u);
  assert.match(text, /#2456/u);
});

// ── integration against a real repository ──────────────────────────────────

function makeRepo() {
  const dir = mkdtempSync(join(tmpdir(), "superseded-pr-"));
  const run = (...args) => execFileSync("git", args, { cwd: dir, encoding: "utf8" });
  run("init", "--quiet", "--initial-branch=main");
  run("config", "user.email", "test@example.com");
  run("config", "user.name", "Test");
  run("config", "commit.gpgsign", "false");
  return { dir, run };
}

test("a reimplemented feature is detected as superseded (the #2456 shape)", () => {
  const { dir, run } = makeRepo();
  try {
    mkdirSync(join(dir, "src"), { recursive: true });
    writeFileSync(join(dir, "src", "seed.txt"), "seed content line here\n");
    run("add", "."); run("commit", "--quiet", "-m", "seed");
    const base = run("rev-parse", "HEAD").trim();

    // The PR branch adds a walkthrough view.
    run("checkout", "--quiet", "-b", "feature");
    const original = [
      "struct MemoryWalkthroughView {",
      "  let spotlightTarget = SettingsAnchor.cloudOverview",
      "  func present() { showTheWalkthroughModal() }",
      "}",
    ].join("\n");
    writeFileSync(join(dir, "src", "walkthrough.swift"), `${original}\n`);
    run("add", "."); run("commit", "--quiet", "-m", "add walkthrough");
    const head = run("rev-parse", "HEAD").trim();

    // Meanwhile main reimplements it independently, keeping every line and
    // adding more — exactly what #2457 did to #2456.
    run("checkout", "--quiet", "main");
    writeFileSync(
      join(dir, "src", "walkthrough.swift"),
      `${original}\nextension MemoryWalkthroughView { func deepLink() {} }\n`,
    );
    run("add", "."); run("commit", "--quiet", "-m", "reimplement walkthrough");

    const result = analyzePullRequest(
      { number: 1, title: "walkthrough", headRefOid: head },
      { baseRef: "main", cwd: dir },
    );
    assert.equal(result.verdict, VERDICTS.SUPERSEDED);
    assert.equal(result.coverage, 1);
    assert.ok(base);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("genuinely novel work is reported active", () => {
  const { dir, run } = makeRepo();
  try {
    writeFileSync(join(dir, "seed.txt"), "seed content line here\n");
    run("add", "."); run("commit", "--quiet", "-m", "seed");

    run("checkout", "--quiet", "-b", "feature");
    writeFileSync(
      join(dir, "novel.mjs"),
      "export const somethingEntirelyNew = () => 42;\nexport const alsoNew = true;\n",
    );
    run("add", "."); run("commit", "--quiet", "-m", "novel work");
    const head = run("rev-parse", "HEAD").trim();
    run("checkout", "--quiet", "main");

    const result = analyzePullRequest(
      { number: 2, title: "novel", headRefOid: head },
      { baseRef: "main", cwd: dir },
    );
    assert.equal(result.verdict, VERDICTS.ACTIVE);
    assert.equal(result.coverage, 0);
    assert.equal(result.files[0].onBase, false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("an unreachable head is indeterminate rather than a crash", () => {
  const { dir, run } = makeRepo();
  try {
    writeFileSync(join(dir, "seed.txt"), "seed content line here\n");
    run("add", "."); run("commit", "--quiet", "-m", "seed");
    const result = analyzePullRequest(
      { number: 3, title: "gone", headRefOid: "0".repeat(40) },
      { baseRef: "main", cwd: dir },
    );
    assert.equal(result.verdict, VERDICTS.INDETERMINATE);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("fileOnRef returns null for a path missing from the ref", () => {
  const { dir, run } = makeRepo();
  try {
    writeFileSync(join(dir, "seed.txt"), "seed content line here\n");
    run("add", "."); run("commit", "--quiet", "-m", "seed");
    assert.equal(fileOnRef("main", "does/not/exist.txt", { cwd: dir }), null);
    assert.notEqual(fileOnRef("main", "seed.txt", { cwd: dir }), null);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
