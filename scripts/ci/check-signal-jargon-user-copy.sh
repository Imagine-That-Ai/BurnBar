#!/usr/bin/env bash
# SOTASIGNAL follow-up — "retire the name from user-facing copy" ratchet.
#
# The Signal at-rest/transport work is wired but NOT activated in production;
# the name may live in code (it is the real library), wire constants
# ("OpenBurnBar-Signal-AAD-v1"), and internal diagnostics — but it must never
# reach copy a user reads: thrown error strings, errorDescription, UI text,
# and rendered site markup. This gate scans shipped source for string literals
# (and rendered markup text) containing the standalone word "Signal" and fails
# on any hit that is NOT on the reviewed allowlist
# (scripts/ci/signal-user-copy-allowlist.txt). The allowlist is the audit trail:
# each entry is a literal a human/agent confirmed is internal-only (a log line,
# a protocol diagnostic, a policy reason) or an honest gated website claim.
#
# Default-deny: a NEW "Signal"-in-a-literal occurrence fails CI until reviewed.
#
# Usage:
#   scripts/ci/check-signal-jargon-user-copy.sh             # scan shipped source
#   scripts/ci/check-signal-jargon-user-copy.sh --self-test # matcher regression
set -euo pipefail
cd "$(dirname "$0")/../.."

ALLOWLIST="scripts/ci/signal-user-copy-allowlist.txt"
MODE="${1:-scan}"

node - "$ALLOWLIST" "$MODE" <<'NODE'
const { readFileSync, existsSync, readdirSync, statSync } = require("node:fs");
const { join } = require("node:path");

const allowlistPath = process.argv[2];
const mode = process.argv[3] || "scan";

// Standalone word "Signal" — NOT "Signal-AAD" wire constants, camelCase
// identifiers (signalEnvelope), or path segments (…/SignalGatewaySessions).
const SIGNAL_WORD = /(?<![A-Za-z0-9_])Signal(?![-A-Za-z0-9_])/;

// A "copy candidate" is any quoted string literal on a non-comment source line
// (Swift/Kotlin/TS `"...", `...`, plus TSX/Astro rendered text below).
const LITERAL = /"([^"\\\n]|\\.)*"|`([^`\\]|\\.)*`/g;

// allowMap: relative-path -> expected hit count (count-bearing so a new literal
// in an already-allowlisted file still trips the gate).
const allowMap = new Map();
if (existsSync(allowlistPath)) {
  for (const line of readFileSync(allowlistPath, "utf8").split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const parts = t.split(" ::: ").map((x) => x.trim());
    if (parts.length < 2 || !/^[0-9]+$/.test(parts[1])) continue;
    allowMap.set(parts[0], Number(parts[1]));
  }
}

function signalLiteralsIn(line, rawMarkup) {
  const trimmed = line.trim();
  if (trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*") || trimmed.startsWith("<!--")) {
    return [];
  }
  if (rawMarkup) {
    // Rendered-markup languages: JSX/Astro text is user-facing even unquoted,
    // so the whole line is the candidate (imports/identifiers lack the
    // standalone word and pass).
    return SIGNAL_WORD.test(line) ? [line] : [];
  }
  const hits = [];
  for (const m of line.matchAll(LITERAL)) {
    if (SIGNAL_WORD.test(m[0])) hits.push(m[0]);
  }
  return hits;
}

if (mode === "--self-test" || mode === "selftest") {
  const FAIL = [
    ["thrown error", '            return "Signal identity is unavailable.";'],
    ["callable error", '  throw new HttpsError("failed-precondition", "Signal identity repair challenge expired.");'],
    ["astro markup", "        We pinned Signal's official open-source library", true],
    ["apos literal", '            return "No Signal identity published."'],
  ];
  const PASS = [
    ["wire constant", '  return "OpenBurnBar-Signal-AAD-v1|" + s;'],
    ["identifier", '    let signalEnvelopeFormatVersion = 1'],
    ["comment", '    // The Signal envelope is additive'],
    ["doc comment", '     * Signal identity for the device'],
    ["path literal", '    .appendingPathComponent("OpenBurnBar/SignalGatewaySessions")'],
    ["lowercase english", '            Text("No quota signal yet")'],
    ["callable name", '    functions.getHttpsCallable("issueTrustedSignalIdentityRepairChallenge")'],
  ];
  let failures = 0;
  for (const [label, line, markup] of FAIL) {
    if (signalLiteralsIn(line, markup === true).length > 0) {
      console.log(`  ok    caught   [${label}]`);
    } else {
      console.error(`  FAIL  missed   [${label}]`);
      failures += 1;
    }
  }
  for (const [label, line] of PASS) {
    if (signalLiteralsIn(line).length === 0) {
      console.log(`  ok    clean    [${label}]`);
    } else {
      console.error(`  FAIL  flagged  [${label}]`);
      failures += 1;
    }
  }
  if (failures === 0) {
    console.log("self-test OK — matcher trips on user-visible Signal literals and ignores internals.");
    process.exit(0);
  }
  console.error(`self-test FAILED — ${failures} matcher regression(s).`);
  process.exit(1);
}

// Shipped source roots. Technical docs (docs/, SECURITY.md, droid-wiki) may
// name Signal accurately — the gate covers copy a non-operator reads.
const ROOTS = [
  "website/src",
  "apps/console/app",
  "apps/console/components",
  "apps/console/lib",
  "AgentLens",
  "OpenBurnBarMobile",
  "OpenBurnBarCore/Sources",
  "OpenBurnBarDaemon/Sources",
  "android/app/src/main",
  "functions/src",
  "functions-sync/src",
  "functions-media/src",
  "functions-identity/src",
];
// packages/*/src individually so generated gen/ + compiled lib/ never scan.
for (const dir of readdirSync("packages")) {
  const src = join("packages", dir, "src");
  if (existsSync(src) && statSync(src).isDirectory()) ROOTS.push(src);
}

const SCAN_EXT = /\.(ts|tsx|jsx|swift|kt|xml|strings|astro)$/;
const MARKUP_EXT = /\.(astro|tsx|jsx)$/;
const EXCLUDE_DIR =
  /(^|\/)(node_modules|dist|build|gen|__snapshots__|out|\.next|lib|__tests__|tests?|Tests|Fixtures|androidTest|resources)(\/|$)/;
const EXCLUDE_FILE =
  /(\.generated\.|\.test\.|Test[s]?\.(swift|kt|ts)$|check-signal-jargon-user-copy|signal-user-copy-allowlist|verify-signal-honesty-copy|signal-honesty-allowlist)/;

const counts = new Map(); // path -> [literal, ...]
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
    const markup = MARKUP_EXT.test(p);
    for (const line of raw.split("\n")) {
      for (const lit of signalLiteralsIn(line, markup)) {
        if (!counts.has(p)) counts.set(p, []);
        counts.get(p).push(lit.length > 100 ? lit.slice(0, 100) + "…" : lit);
      }
    }
  }
}
for (const r of ROOTS) scan(r);

let failures = 0;
for (const [file, lits] of counts) {
  const expected = allowMap.get(file);
  if (expected === undefined) {
    console.error(`  FAIL ${file}: ${lits.length} unreviewed "Signal" literal(s)`);
    for (const l of lits) console.error(`       ${l}`);
    failures += lits.length;
  } else if (expected !== lits.length) {
    console.error(`  FAIL ${file}: ${lits.length} "Signal" literal(s), allowlist expects ${expected} — review the delta`);
    for (const l of lits) console.error(`       ${l}`);
    failures += 1;
  } else {
    console.log(`  ok   ${file}: ${lits.length} allowlisted literal(s)`);
  }
}
for (const [file, expected] of allowMap) {
  if (!counts.has(file)) {
    console.error(`  FAIL ${file}: allowlist expects ${expected} hit(s), found none — clean up the entry`);
    failures += 1;
  }
}
if (failures > 0) {
  console.error(`\n${failures} unreviewed "Signal" jargon hit(s). If a literal is genuinely internal-only,`);
  console.error(`add it to ${allowlistPath} with a comment justifying why users never see it.`);
  process.exit(1);
}
console.log("\nSignal user-copy scan OK — no unreviewed jargon literals.");
NODE
