#!/usr/bin/env node

// Find open pull requests whose content has already landed on the base branch.
//
// WHY THIS EXISTS (BurnBar #2456, 2026-09-02): #2456 sat APPROVED and
// CONFLICTING for days. Its feature — the Memory MCP walkthrough — had already
// shipped in #2457, which *reimplemented* it rather than merging it, and #2461
// then improved it further. Rebasing #2456 would have replayed the older
// revision over the newer one and regressed main. Nothing in the PR's metadata
// says any of this: it was approved, it was mergeable-once, and its checks were
// green. With 93 open PRs, that class of zombie is invisible by hand.
//
// WHY CONTENT COVERAGE AND NOT ANCESTRY: the obvious implementations do not
// work here.
//   - `git merge-base` / ancestry: #2457 shares no commits with #2456. A
//     reimplementation is topologically unrelated to the branch it obsoletes.
//   - `git merge-tree` / empty-diff: only catches the exact-duplicate case. It
//     misses the common one, where main's copy has since moved ahead (main's
//     MemoryMCPWalkthroughView.swift was 616 lines to the branch's 555).
//   - `gh pr view --json state`: reports OPEN, because it is open.
// The only signal that survives a reimplementation is whether the lines the PR
// *adds* can already be found on the base branch. That is what this measures.
//
// The verdict is advisory. It answers "is this PR's content already on main",
// which is evidence for closing a PR — never an instruction to close one. No
// mode of this script writes to GitHub.

import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

export const VERDICTS = Object.freeze({
  SUPERSEDED: "superseded",
  PARTIAL: "partially-landed",
  ACTIVE: "active",
  INDETERMINATE: "indeterminate",
});

// A PR is called superseded only when nearly every line it adds is already on
// the base branch. The gap below 1.0 absorbs import reordering and the handful
// of lines a reimplementation renames; it is deliberately tight, because a
// false "superseded" invites closing live work.
export const DEFAULT_SUPERSEDED_THRESHOLD = 0.95;
export const DEFAULT_PARTIAL_THRESHOLD = 0.5;

// Lines shorter than this, or carrying no identifier characters, are structural
// noise — `}`, `});`, `end`, blank lines, lone braces. They appear in every file
// in the repository, so counting them as "already present on main" would mark
// essentially every PR superseded. Excluding them is what makes the ratio mean
// something. This is the single most important knob in the file.
export const MIN_SIGNIFICANT_LENGTH = 8;

const IDENTIFIER_PATTERN = /[A-Za-z0-9_]/u;

/**
 * True when a line carries enough substance that finding it on the base branch
 * is real evidence, rather than a coincidence of shared syntax.
 */
export function isSignificantLine(line) {
  const trimmed = line.trim();
  if (trimmed.length < MIN_SIGNIFICANT_LENGTH) return false;
  return IDENTIFIER_PATTERN.test(trimmed);
}

/**
 * Parse a unified diff into per-path added lines.
 *
 * Only `+` lines are collected: the question is "does main already contain what
 * this PR introduces", and removals cannot answer it. File headers (`+++ b/x`)
 * are excluded, and binary files are flagged so the caller can refuse to judge
 * them rather than scoring them zero.
 */
export function parseUnifiedDiff(diffText) {
  const files = new Map();
  let current = null;

  const ensure = (path) => {
    if (!files.has(path)) {
      files.set(path, { path, added: [], binary: false });
    }
    return files.get(path);
  };

  for (const line of String(diffText).split("\n")) {
    const header = /^diff --git a\/(.+?) b\/(.+)$/u.exec(line);
    if (header) {
      // Use the post-image path so renames are attributed to where the content
      // now lives, which is the path we will look up on the base branch.
      current = ensure(header[2]);
      continue;
    }
    if (!current) continue;
    if (line.startsWith("Binary files ") || line.startsWith("GIT binary patch")) {
      current.binary = true;
      continue;
    }
    if (line.startsWith("+++") || line.startsWith("---")) continue;
    if (line.startsWith("+")) current.added.push(line.slice(1));
  }

  return files;
}

/**
 * Score one file: how many of its significant added lines already exist in
 * `baseContent`. `baseContent` is null when the path does not exist on the base
 * branch at all, which is decisive evidence the work has *not* landed.
 */
export function scoreFile({ added, baseContent }) {
  const significant = added.filter(isSignificantLine).map((line) => line.trim());
  if (significant.length === 0) {
    return { significant: 0, present: 0, ratio: null };
  }
  if (baseContent === null || baseContent === undefined) {
    return { significant: significant.length, present: 0, ratio: 0 };
  }
  const haystack = new Set(
    String(baseContent)
      .split("\n")
      .map((line) => line.trim()),
  );
  const present = significant.filter((line) => haystack.has(line)).length;
  return {
    significant: significant.length,
    present,
    ratio: present / significant.length,
  };
}

/**
 * Aggregate per-file scores into a verdict.
 *
 * Pooling lines rather than averaging per-file ratios keeps a one-line README
 * tweak from outvoting a 600-line implementation file.
 */
export function classify(
  fileScores,
  {
    supersededThreshold = DEFAULT_SUPERSEDED_THRESHOLD,
    partialThreshold = DEFAULT_PARTIAL_THRESHOLD,
  } = {},
) {
  let significant = 0;
  let present = 0;
  for (const score of fileScores) {
    significant += score.significant;
    present += score.present;
  }

  // No significant added lines at all: a pure deletion, a lockfile-only bump, a
  // binary asset. There is nothing to find on main, so refuse to guess.
  if (significant === 0) {
    return { verdict: VERDICTS.INDETERMINATE, coverage: null, significant, present };
  }

  const coverage = present / significant;
  const verdict =
    coverage >= supersededThreshold
      ? VERDICTS.SUPERSEDED
      : coverage >= partialThreshold
        ? VERDICTS.PARTIAL
        : VERDICTS.ACTIVE;
  return { verdict, coverage, significant, present };
}

// ── git / gh access ────────────────────────────────────────────────────────

function git(args, { cwd = process.cwd(), allowFailure = false } = {}) {
  try {
    return execFileSync("git", args, {
      cwd,
      encoding: "utf8",
      maxBuffer: 256 * 1024 * 1024,
    });
  } catch (error) {
    if (allowFailure) return null;
    throw error;
  }
}

export function fileOnRef(ref, path, options = {}) {
  return git(["show", `${ref}:${path}`], { ...options, allowFailure: true });
}

export function listOpenPullRequests({ repo, limit = 200, cwd } = {}) {
  const raw = execFileSync(
    "gh",
    [
      "pr",
      "list",
      ...(repo ? ["--repo", repo] : []),
      "--state",
      "open",
      "--limit",
      String(limit),
      "--json",
      "number,title,headRefName,headRefOid,baseRefName,mergeable,reviewDecision,isDraft,updatedAt",
    ],
    { cwd, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
  );
  return JSON.parse(raw);
}

/**
 * Make every open PR head available locally. GitHub publishes them as
 * `refs/pull/<n>/head`; without this the head OIDs are unknown objects and every
 * diff below fails.
 */
export function fetchPullRequestHeads({ cwd, remote = "origin" } = {}) {
  git(
    ["fetch", "--quiet", remote, "+refs/pull/*/head:refs/remotes/pr-triage/*"],
    { cwd, allowFailure: true },
  );
}

/**
 * Score a single PR against the base branch.
 *
 * The diff is taken from the merge base, not from the base tip: we want the
 * lines this PR introduces, not every line main has moved on without it.
 */
export function analyzePullRequest(pr, { baseRef, cwd } = {}) {
  const head = pr.headRefOid;
  const mergeBase = git(["merge-base", baseRef, head], { cwd, allowFailure: true });
  if (mergeBase === null) {
    return { ...pr, verdict: VERDICTS.INDETERMINATE, coverage: null, reason: "head unavailable" };
  }
  const diff = git(
    ["diff", "--no-color", "--no-ext-diff", `${mergeBase.trim()}..${head}`],
    { cwd, allowFailure: true },
  );
  if (diff === null) {
    return { ...pr, verdict: VERDICTS.INDETERMINATE, coverage: null, reason: "diff unavailable" };
  }

  const parsed = parseUnifiedDiff(diff);
  const fileScores = [];
  const files = [];
  for (const entry of parsed.values()) {
    if (entry.binary) continue;
    const baseContent = fileOnRef(baseRef, entry.path, { cwd });
    const score = scoreFile({ added: entry.added, baseContent });
    fileScores.push(score);
    files.push({
      path: entry.path,
      onBase: baseContent !== null,
      ...score,
    });
  }

  const result = classify(fileScores);
  return { ...pr, ...result, files };
}

// ── CLI ────────────────────────────────────────────────────────────────────

function argument(argv, flag, fallback) {
  const index = argv.indexOf(flag);
  if (index === -1 || index === argv.length - 1) return fallback;
  return argv[index + 1];
}

export function formatReport(results) {
  const order = [VERDICTS.SUPERSEDED, VERDICTS.PARTIAL, VERDICTS.ACTIVE, VERDICTS.INDETERMINATE];
  const lines = [];
  for (const verdict of order) {
    const bucket = results.filter((result) => result.verdict === verdict);
    if (bucket.length === 0) continue;
    lines.push(`\n${verdict.toUpperCase()} (${bucket.length})`);
    bucket.sort((a, b) => (b.coverage ?? 0) - (a.coverage ?? 0));
    for (const result of bucket) {
      const pct = result.coverage === null ? "  n/a" : `${(result.coverage * 100).toFixed(0).padStart(3)}%`;
      lines.push(`  ${pct}  #${String(result.number).padEnd(5)} ${result.title}`);
    }
  }
  return lines.join("\n");
}

export function run(argv) {
  const repo = argument(argv, "--repo");
  const baseRef = argument(argv, "--base", "origin/main");
  const limit = Number(argument(argv, "--limit", "200"));
  const cwd = argument(argv, "--cwd", process.cwd());
  const asJson = argv.includes("--json");

  const prs = listOpenPullRequests({ repo, limit, cwd });
  fetchPullRequestHeads({ cwd });

  const results = prs.map((pr) => analyzePullRequest(pr, { baseRef, cwd }));

  if (asJson) {
    process.stdout.write(`${JSON.stringify({ schemaVersion: 1, baseRef, results }, null, 2)}\n`);
    return results;
  }
  process.stdout.write(`${formatReport(results)}\n`);
  return results;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  run(process.argv.slice(2));
}
