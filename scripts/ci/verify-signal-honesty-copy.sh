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
# Usage:
#   scripts/ci/verify-signal-honesty-copy.sh             # scan the repo copy surfaces
#   scripts/ci/verify-signal-honesty-copy.sh --self-test # prove the BANNED matcher
#       fails on the known §9.2/App.E over-claims and passes on the caveated
#       rewrites (no filesystem scan; pure matcher regression).
set -euo pipefail
cd "$(dirname "$0")/../.."

ALLOWLIST="scripts/ci/signal-honesty-allowlist.txt"
MODE="${1:-scan}"

node - "$ALLOWLIST" "$MODE" <<'NODE'
const { readFileSync, existsSync, readdirSync, statSync } = require("node:fs");
const { join } = require("node:path");

const allowlistPath = process.argv[2];
const mode = process.argv[3] || "scan";
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
  "semantic memory is private from us",
  "semantic search is private from us",
  "server cannot infer semantic",
  "server cannot infer memory",
  "revocation immediately makes old data safe",
  // Cure53 §9.2 / App. E (2026-06-12): block the specific product-facing
  // OVER-CLAIM forms that imply BurnBar/relay can never read your data, that
  // keys never leave the device, or that the product is wholesale "end-to-end
  // encrypted" with no caveat. These are deliberately narrow exact phrases so
  // the gate catches the REGRESSED Floo/feature/Remote-Unlock copy without
  // false-positiving the dozens of correctly-SCOPED "end-to-end encrypted"
  // uses (a specific domain/feature) or the qualified "never leave the device"
  // survivors (logs, vault keys, Signal prekey halves).
  "no one in the middle",                          // old Floo FAQ + floo.astro absolute
  "that includes us",                              // "...and that includes us" relay absolute
  "couldn't peek",                                 // "couldn't peek even if we wanted to" absolute
  "everything between them is end-to-end encrypted", // unqualified product-wide E2E label (old Floo)
  "api keys never leave the device",               // §9.2-5 API-key over-claim (droid-wiki/features) — scoped to "API keys" so it does NOT trip the accurate "private keys never leave the device Keychain"
  "never leave the providers",                     // "API keys never leave the providers you already trust"
  "never appears in a log",                        // §9.2-8 Remote Unlock "never appears in a log/server"
];

// Shared matcher: does `text` contain any banned phrase (case-insensitive)?
function bannedPhraseIn(text) {
  const lower = text.toLowerCase();
  for (const phrase of BANNED) if (lower.includes(phrase)) return phrase;
  return null;
}

// --- Self-test mode (scripts/ci/verify-signal-honesty-copy.sh --self-test) ---
// Regression proof for the §9.2/App.E additions: the EXACT over-claim strings
// that shipped (and were rewritten) must trip the matcher, and the caveated
// rewrites that replaced them must NOT. This is the "would FAIL on the old
// strings" check, runnable in CI without scanning the tree.
if (mode === "--self-test" || mode === "selftest") {
  // [label, text] — these MUST be caught (the removed over-claims).
  const MUST_FAIL = [
    ["faq.ts old Floo", "everything between them is end-to-end encrypted — no one in the middle can read it, and that includes us."],
    ["floo.astro old safe-by-design", "The connection is private end to end — and that includes us. We built it so we couldn't peek even if we wanted to."],
    ["features.ts old API-key", "Your API keys never leave the providers you already trust."],
    ["droid-wiki old API-key", "API keys never leave the device; P2P sessions are cryptographically authenticated."],
    ["capabilities.ts old Remote Unlock", "it never appears in a log, a server, or anywhere you didn't put it."],
  ];
  // [label, text] — these MUST NOT be caught (the caveated rewrites + known
  // correctly-scoped survivors the gate must not regress on).
  const MUST_PASS = [
    ["faq.ts new Floo", "the screen, control, file, and clipboard contents are sealed end-to-end between your devices — the relay sees routing metadata, never those contents."],
    ["features.ts new API-key", "Your BYOK keys are stored in the macOS Keychain and sent only to the providers you choose — BurnBar's servers never receive them in plaintext."],
    ["capabilities.ts new Remote Unlock", "it never lands in a BurnBar log or on our servers; only your Mac opens it to type it locally."],
    ["scoped E2E survivor", "Assistant chats are sealed on-device; this domain is end-to-end encrypted."],
    ["qualified never-leave survivor (logs)", "Logs stay in the local SQLite store and never leave the device unless you enable an opt-in mirror."],
    ["qualified never-leave survivor (vault keys)", "Your private keys never leave the device Keychain."],
  ];
  let failures = 0;
  for (const [label, text] of MUST_FAIL) {
    const hit = bannedPhraseIn(text);
    if (hit) {
      console.log(`  ok    MUST-FAIL caught  [${label}]  via "${hit}"`);
    } else {
      console.error(`  FAIL  MUST-FAIL NOT caught  [${label}]  — gate would let the over-claim through`);
      failures += 1;
    }
  }
  for (const [label, text] of MUST_PASS) {
    const hit = bannedPhraseIn(text);
    if (!hit) {
      console.log(`  ok    MUST-PASS clean      [${label}]`);
    } else {
      console.error(`  FAIL  MUST-PASS false-positive  [${label}]  via "${hit}"  — gate over-blocks caveated copy`);
      failures += 1;
    }
  }
  if (failures === 0) {
    console.log("self-test OK — banned matcher trips on the §9.2 over-claims and passes the caveated rewrites.");
    process.exit(0);
  }
  console.error(`self-test FAILED — ${failures} matcher regression(s).`);
  process.exit(1);
}

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
  /(docs\/signalification\/|docs\/security\/BurnBar-threat-model\.md|SOTA_REMEDIATION|SECURITY_CLAIMS_REGISTER|signal-honesty-allowlist|verify-signal-honesty-copy|HERMES_GATEWAY_E2EE_REMEDIATION)/;
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
