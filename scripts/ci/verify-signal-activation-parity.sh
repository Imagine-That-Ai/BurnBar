#!/usr/bin/env bash
# SOTASIGNAL Phase F / L11 / L34 — activation parity & fail-closed default gate.
#
# The Signal feature has several independent activation levers (compile-time
# constants, the data-domains registry sealingScheme, and — at Phase E — a Remote
# Config template). They MUST agree. By default they MUST all read "OFF / empty /
# fail-closed"; Phase-E activation is allowed only when the strict activation
# evidence bundle validates first. This script is a drift gate: accidental
# activation fails CI, but a signed-off activation is not blocked by an
# always-off assertion.
#
# Usage:
#   scripts/ci/verify-signal-activation-parity.sh
#   scripts/ci/verify-signal-activation-parity.sh --mode activation --activation-evidence path/to/signal-activation-evidence.json
set -euo pipefail
cd "$(dirname "$0")/../.."

node - "$@" <<'NODE'
const { spawnSync } = require("node:child_process");
const { readFileSync, existsSync, readdirSync, statSync } = require("node:fs");
const { join } = require("node:path");

let failures = 0;
const fail = (m) => { console.error(`  FAIL ${m}`); failures += 1; };
const ok = (m) => console.log(`  ok   ${m}`);

function usage() {
  return `Usage:
  scripts/ci/verify-signal-activation-parity.sh
  scripts/ci/verify-signal-activation-parity.sh --mode activation --activation-evidence path/to/signal-activation-evidence.json

Modes:
  default     Require every Signal activation lever to stay OFF/fail-closed.
  activation  Allow ON levers only after validate-signal-activation-evidence.mjs passes.`;
}

function parseArgs(argv) {
  const out = { mode: "default", activationEvidence: process.env.SIGNAL_ACTIVATION_EVIDENCE || "" };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      console.log(usage());
      process.exit(0);
    }
    if (arg === "--mode") {
      out.mode = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--mode=")) {
      out.mode = arg.slice("--mode=".length);
      continue;
    }
    if (arg === "--activation-evidence") {
      out.activationEvidence = argv[++i] || "";
      continue;
    }
    if (arg.startsWith("--activation-evidence=")) {
      out.activationEvidence = arg.slice("--activation-evidence=".length);
      continue;
    }
    fail(`unknown argument: ${arg}`);
  }
  if (!["default", "activation"].includes(out.mode)) fail(`--mode must be default or activation, got ${out.mode}`);
  return out;
}

function validateActivationEvidence(path) {
  if (!path) {
    fail("--mode activation requires --activation-evidence or SIGNAL_ACTIVATION_EVIDENCE");
    return false;
  }
  const result = spawnSync(process.execPath, ["scripts/ci/validate-signal-activation-evidence.mjs", path], {
    cwd: process.cwd(),
    encoding: "utf8",
  });
  if (result.status === 0) {
    ok(`activation evidence validated: ${path}`);
    return true;
  }
  fail(`activation evidence did not validate: ${path}`);
  const detail = `${result.stdout || ""}${result.stderr || ""}`.trim();
  if (detail) console.error(detail.split("\n").map((line) => `       ${line}`).join("\n"));
  return false;
}

const args = parseArgs(process.argv.slice(2));
const activationMode = args.mode === "activation";
const activationEvidenceOK = activationMode ? validateActivationEvidence(args.activationEvidence) : false;

// (1) Gateway transport: the PRODUCTION envelope-versions set must be EMPTY.
const gw = readFileSync("functions/src/hermesGateway.ts", "utf8");
const productionSignalEmpty = /HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS\s*=\s*new Set<number>\(\s*\)/.test(gw);
const productionSignalV4 =
  /HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS\s*=\s*new Set<number>\(\s*\[\s*(?:4|HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL)\s*\]\s*\)/.test(gw);
if (!activationMode && productionSignalEmpty) {
  ok("HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS is empty (transport fail-closed)");
} else if (!activationMode) {
  fail("HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS is NOT empty — production v4 would be accepted");
} else if (activationEvidenceOK && productionSignalV4) {
  ok("HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS enables v4 with validated activation evidence");
} else {
  fail("activation mode requires HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS to enable v4");
}

// (2) Data-domains registry: default mode has no Signal sealingScheme; activation
// mode permits it only after the evidence bundle validates.
const registry = JSON.parse(readFileSync("packages/data-domains/registry.json", "utf8"));
const domains = registry.domains ?? [];
const activated = domains.filter(
  (d) => typeof d.sealingScheme === "string" && /signal/i.test(d.sealingScheme),
);
if (!activationMode && activated.length === 0) {
  ok(`no domain carries a 'signal' sealingScheme (${domains.length} domains, all cloudvault default)`);
} else if (!activationMode) {
  fail(`domains already on a signal sealingScheme: ${activated.map((d) => `${d.id}=${d.sealingScheme}`).join(", ")}`);
} else if (activationEvidenceOK && activated.length > 0) {
  ok(`Signal sealingScheme active with validated evidence: ${activated.map((d) => d.id).join(", ")}`);
} else {
  fail("activation mode requires at least one data-domain Signal sealingScheme after evidence validates");
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
    if (m && activationMode && activationEvidenceOK) {
      ok(`Remote Config template ${p} sets Signal flag ${m[1]} under validated activation evidence`);
    } else if (m) {
      fail(`Remote Config template ${p} sets a Signal flag ON: ${m[1]}`);
    }
  }
}
scan("launch-evidence");
scan("remoteconfig");
if (!activationMode) {
  ok("no committed Remote Config template flips a Signal flag ON");
} else if (activationEvidenceOK) {
  ok("Remote Config Signal flags are allowed only under the validated activation evidence boundary");
}

console.log(failures === 0
  ? `\nactivation parity OK — Signal levers match ${activationMode ? "validated Phase-E activation" : "the fail-closed default"}.`
  : `\nactivation parity FAILED — ${failures} lever(s) drifted from the ${activationMode ? "validated activation" : "safe default"} posture.`);
process.exit(failures === 0 ? 0 : 1);
NODE
