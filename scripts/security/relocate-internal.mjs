#!/usr/bin/env node
// Relocate block-severity internal files out of the public tree into internal/.
//
// Uses the SAME classifier as the confidentiality guard, so the move list can
// never drift from what the guard enforces. Dry-run by default.
//
//   node scripts/security/relocate-internal.mjs           # preview
//   node scripts/security/relocate-internal.mjs --apply    # move + stage deletions
//
// After --apply: files live under internal/<original-path> (gitignored) and the
// originals are removed from the git index. History still contains them — run
// the purge runbook (docs/security/PUBLIC_REPO_HISTORY_PURGE_RUNBOOK.md) to
// scrub history and rotate any exposed credentials.

import { execFileSync } from "node:child_process";
import { mkdirSync, renameSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { scan, repoRoot, trackedFiles, makeReader } from "./scan-internal-content.mjs";
import { PRIVATE_HOME } from "./internal-content-policy.mjs";

const apply = process.argv.includes("--apply");
const root = repoRoot();
const { blocking } = scan(trackedFiles(root), makeReader(root));

if (blocking.length === 0) {
  console.log("Nothing to relocate — public tree is clean.");
  process.exit(0);
}

console.log(
  `${apply ? "Relocating" : "[dry-run] would relocate"} ${blocking.length} file(s) into ${PRIVATE_HOME}\n`,
);

let moved = 0;
for (const { path, ruleId } of blocking) {
  const dest = join(PRIVATE_HOME, path);
  console.log(`  ${path}  →  ${dest}   [${ruleId}]`);
  if (!apply) continue;
  const absSrc = join(root, path);
  const absDest = join(root, dest);
  if (!existsSync(absSrc)) {
    console.warn(`    (skip: source missing)`);
    continue;
  }
  mkdirSync(dirname(absDest), { recursive: true });
  renameSync(absSrc, absDest);
  // Stage the deletion from the index (works even though the worktree file moved).
  execFileSync("git", ["rm", "--cached", "--quiet", "--", path], { cwd: root });
  moved++;
}

if (apply) {
  console.log(`\nMoved ${moved} file(s). Verifying guard…`);
  const after = scan(trackedFiles(root), makeReader(root));
  if (after.blocking.length === 0) {
    console.log("✓ Public tree is now clean of block-severity internal content.");
  } else {
    console.error(`✖ ${after.blocking.length} still flagged — investigate.`);
    process.exit(1);
  }
} else {
  console.log(`\nRe-run with --apply to perform the move.`);
}
