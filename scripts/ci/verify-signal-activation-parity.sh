#!/usr/bin/env bash
# SOTASIGNAL Phase F / L11 / L34 — activation parity & fail-closed default gate.
#
# The Signal feature has several independent activation levers (compile-time
# constants, the data-domains registry sealingScheme, and — at Phase E — a Remote
# Config template). They MUST agree, and until Phase E they MUST all read "OFF /
# empty / fail-closed". This script asserts the shipped constants encode that safe
# default and that no committed Remote Config template silently flips a Signal flag
# ON. It is a drift gate: any accidental activation fails CI.
#
# Usage: scripts/ci/verify-signal-activation-parity.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

node - <<'NODE'
const { readFileSync, existsSync, readdirSync, statSync } = require("node:fs");
const { join } = require("node:path");

let failures = 0;
const fail = (m) => { console.error(`  FAIL ${m}`); failures += 1; };
const ok = (m) => console.log(`  ok   ${m}`);

// (1) Gateway transport: the PRODUCTION envelope-versions set must be EMPTY.
const gw = readFileSync("functions/src/hermesGateway.ts", "utf8");
if (/HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS\s*=\s*new Set<number>\(\s*\)/.test(gw)) {
  ok("HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS is empty (transport fail-closed)");
} else {
  fail("HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS is NOT empty — production v4 would be accepted");
}

// (2) Data-domains registry: no end_to_end domain may have a 'signal' sealingScheme.
const registry = JSON.parse(readFileSync("packages/data-domains/registry.json", "utf8"));
const domains = registry.domains ?? [];
const activated = domains.filter(
  (d) => typeof d.sealingScheme === "string" && /signal/i.test(d.sealingScheme),
);
if (activated.length === 0) {
  ok(`no domain carries a 'signal' sealingScheme (${domains.length} domains, all cloudvault default)`);
} else {
  fail(`domains already on a signal sealingScheme: ${activated.map((d) => `${d.id}=${d.sealingScheme}`).join(", ")}`);
}

// (2b) Producer-coverage honesty gate: the gate is keyed by DOMAIN id but producers
// are per-collection. A domain that carries the Signal scheme MUST declare
// signalSealedCollections — the EXACT subset of its firestorePaths that actually emit a
// signalEnvelope — so the registry can never silently over-claim that an unwired
// collection is Signal-sealed. (Pure documentation today; once the runtime gate is made
// collection-aware it becomes the source of truth. No-op until a domain is flipped.)
for (const d of activated) {
  const sealed = d.signalSealedCollections;
  if (!Array.isArray(sealed) || sealed.length === 0) {
    fail(`${d.id} carries the Signal scheme but does not declare a non-empty signalSealedCollections`);
    continue;
  }
  const paths = new Set(d.firestorePaths ?? []);
  const stray = sealed.filter((c) => !paths.has(c));
  if (stray.length) {
    fail(`${d.id} signalSealedCollections lists collections not in its firestorePaths: ${stray.join(", ")}`);
  } else {
    ok(`${d.id} declares signalSealedCollections (${sealed.length}/${paths.size} collections Signal-sealed): ${sealed.join(", ")}`);
  }
}

// (3) No committed Remote Config template may set a Signal flag true.
const SIGNAL_RC_KEYS = /(signal_envelope_v4_enabled|signal_at_rest_[a-z_]+_enabled|escrow_fingerprint_enforcement)/;
function scan(dir) {
  if (!existsSync(dir)) return;
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    const s = statSync(p);
    if (s.isDirectory()) { scan(p); continue; }
    if (!/\.json$/.test(entry)) continue;
    let raw;
    try { raw = readFileSync(p, "utf8"); } catch { continue; }
    if (!SIGNAL_RC_KEYS.test(raw)) continue;
    // A signal RC key is present; ensure it is not set true.
    const m = raw.match(new RegExp(`"(${SIGNAL_RC_KEYS.source})"\\s*:\\s*\\{[^}]*"defaultValue"[^}]*(true|"true")`, "i"));
    if (m) fail(`Remote Config template ${p} sets a Signal flag ON: ${m[1]}`);
  }
}
scan("launch-evidence");
scan("remoteconfig");
ok("no committed Remote Config template flips a Signal flag ON");

console.log(failures === 0
  ? "\nactivation parity OK — all Signal levers are at the fail-closed default."
  : `\nactivation parity FAILED — ${failures} lever(s) drifted from the safe default.`);
process.exit(failures === 0 ? 0 : 1);
NODE
