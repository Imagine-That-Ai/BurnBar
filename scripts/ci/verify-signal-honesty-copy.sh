#!/usr/bin/env bash
# SOTASIGNAL Phase F / L21 / Honesty-and-Copy gate.
#
# The plan BANS over-claim phrases ("zero-knowledge", "server learns nothing",
# "Signal-quality privacy", "searches without reading it", "revocation immediately
# makes old data safe") in product-facing copy unless paired with an explicit
# residual-leak caveat. This gate greps the product/copy surfaces for those phrases
# and fails on any hit that is NOT on the reviewed allowlist
# (scripts/ci/signal-honesty-allowlist.txt). The allowlist is the audit trail: each
# entry is a phrase a human/agent reviewed and either (a) accompanied with the
# required disclosure, or (b) confirmed internal-only (not shipped to users).
#
# Default-deny: a NEW banned-phrase occurrence fails CI until reviewed + allowlisted.
#
# Usage: scripts/ci/verify-signal-honesty-copy.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

ALLOWLIST="scripts/ci/signal-honesty-allowlist.txt"

node - "$ALLOWLIST" <<'NODE'
const { readFileSync, existsSync, readdirSync, statSync } = require("node:fs");
const { join } = require("node:path");

const allowlistPath = process.argv[2];
// allowMap: key -> expectedCount (number) OR null (lenient: any count).
// Line format: <relative-path> ::: <phrase> [ ::: <expected-count> ]
// A count makes the entry COUNT-BEARING: a NEW occurrence of an already-allowlisted
// phrase in the same file (or a removed one) trips the gate and forces re-review,
// closing the file+phrase-only bypass.
const allowMap = new Map();
if (existsSync(allowlistPath)) {
  for (const line of readFileSync(allowlistPath, "utf8").split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const parts = t.split(" ::: ").map((x) => x.trim());
    if (parts.length < 2) continue;
    const key = `${parts[0]}::${parts[1].toLowerCase()}`;
    const count = parts.length >= 3 && /^[0-9]+$/.test(parts[2]) ? Number(parts[2]) : null;
    allowMap.set(key, count);
  }
}

// Banned phrases (case-insensitive). Keep in sync with the plan's Honesty policy.
const BANNED = [
  "zero-knowledge",
  "zero knowledge",
  "server learns nothing",
  "server searches without reading it",
  "searches without reading",
  "search without reading", // singular form — caught e.g. "runs ANN search without reading"
  "signal-quality privacy",
  "revocation immediately makes old data safe",
];

// Product / copy surfaces to scan. Includes the macOS (AgentLens) + Android app
// UI source — the genuinely user-facing copy the gate previously missed. We exclude
// build output, deps, and the signalification plan docs themselves (which quote the
// banned phrases by design), plus this gate + its allowlist.
const ROOTS = ["website/src", "functions/src", "packages", "docs", "AgentLens", "android/app/src/main", "OpenBurnBarMobile", "OpenBurnBarCore/Sources", "apps/console/app", "apps/console/components", "apps/console/lib"];
// NOTE: the `lib` exclusion is scoped to compiled-output trees (packages/*/lib,
// functions/lib) so it does NOT swallow hand-written Next.js source under
// apps/console/lib (which holds the deployed console's domain copy). `out`/`.next`
// are the console build artifacts and stay excluded. (Remediation R3/R8.)
const EXCLUDE_DIR = /(^|\/)(node_modules|dist|build|gen|__snapshots__|out|\.next)(\/|$)|(^|\/)(packages\/[^/]+|functions)\/lib(\/|$)/;
const EXCLUDE_FILE =
  /(docs\/signalification\/|SOTA_REMEDIATION|signal-honesty-allowlist|verify-signal-honesty-copy|HERMES_GATEWAY_E2EE_REMEDIATION)/;
const SCAN_EXT = /\.(ts|tsx|astro|md|mdx|json|swift|kt|xml|strings)$/;

const hits = new Map(); // key -> { count, firstLine, file, phrase }

function scan(dir) {
  if (!existsSync(dir)) return;
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (EXCLUDE_DIR.test(p)) continue;
    let s;
    try { s = statSync(p); } catch { continue; }
    if (s.isDirectory()) { scan(p); continue; }
    if (!SCAN_EXT.test(p) || EXCLUDE_FILE.test(p)) continue;
    let raw;
    try { raw = readFileSync(p, "utf8"); } catch { continue; }
    const lower = raw.toLowerCase();
    for (const phrase of BANNED) {
      let idx = lower.indexOf(phrase);
      while (idx >= 0) {
        const key = `${p}::${phrase}`;
        const rec = hits.get(key) || { count: 0, firstLine: raw.slice(0, idx).split("\n").length, file: p, phrase };
        rec.count += 1;
        hits.set(key, rec);
        idx = lower.indexOf(phrase, idx + phrase.length);
      }
    }
  }
}

for (const r of ROOTS) scan(r);

let violations = 0;
let reviewed = 0;
for (const [key, rec] of hits) {
  if (!allowMap.has(key)) {
    console.error(`  BANNED  ${rec.file}:${rec.firstLine}  "${rec.phrase}" x${rec.count}  (not on honesty allowlist)`);
    violations += 1;
    continue;
  }
  const expected = allowMap.get(key);
  if (expected !== null && expected !== rec.count) {
    console.error(`  COUNT   ${rec.file}  "${rec.phrase}"  expected ${expected} reviewed occurrence(s), found ${rec.count} — re-review + update the allowlist count`);
    violations += 1;
    continue;
  }
  reviewed += 1;
}
// Stale allowlist entries (allowlisted but no current occurrence) — warn, do not fail.
for (const key of allowMap.keys()) {
  if (!hits.has(key)) console.log(`  note   stale allowlist entry (no current occurrence): ${key}`);
}

console.log(`  reviewed/allowlisted (file,phrase) pairs: ${reviewed}`);
if (violations === 0) {
  console.log("honesty copy OK — no un-reviewed over-claim phrases in product/copy surfaces.");
  process.exit(0);
}
console.log(`honesty copy FAILED — ${violations} un-reviewed/over-count over-claim(s). Add a caveat or update the allowlist with justification.`);
process.exit(1);
NODE
