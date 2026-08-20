#!/usr/bin/env bash
# SOTASIGNAL Phase F / L11 / L34 — activation parity & fail-closed default gate.
#
# The Signal feature has several independent activation levers (compile-time
# constants, the data-domains registry sealingScheme, runtime required flags, hard
# kills, and Remote Config). They MUST agree: binaries may be Signal-capable while
# every committed/default runtime lever stays OFF. This script verifies both the
# guarded activation path and the fail-closed default.
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
// The envelope constants live in their own module after the Hermes Gateway
// split; keep this gate pointed at the source of truth instead of the wrapper.
const gw = readFileSync("functions/src/hermesGatewayEnvelope.ts", "utf8");
if (/HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS\s*=\s*new Set<number>\(\s*\)/.test(gw)) {
  ok("HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS is empty (transport fail-closed)");
} else {
  fail("HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS is NOT empty — production v4 would be accepted");
}
if (/gatewaySignalEnvelopeV4Disabled\(\)[\s\S]*return new Set<number>\(\)[\s\S]*gatewaySignalRequiredMode\(\)[\s\S]*HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL/.test(gw)) {
  ok("gateway v4 activation requires required-mode and remains subordinate to the hard kill");
} else {
  fail("gateway v4 required-mode / hard-kill activation contract drifted");
}

// (2) Data-domains registry: conversations_chat is compiled Signal-capable and
// declares all ten private producers. Runtime Remote Config remains OFF below.
const registry = JSON.parse(readFileSync("packages/data-domains/registry.json", "utf8"));
const domains = registry.domains ?? [];
const activated = domains.filter(
  (d) => typeof d.sealingScheme === "string" && /signal/i.test(d.sealingScheme),
);
if (activated.length === 1 && activated[0].id === "conversations_chat") {
  ok("conversations_chat is the only Signal-capable data domain");
} else {
  fail(`expected only conversations_chat on a Signal scheme; got: ${activated.map((d) => `${d.id}=${d.sealingScheme}`).join(", ") || "none"}`);
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
  if (d.id === "conversations_chat") {
    // Pin the EXACT set of Signal producers by name (stronger than the old
    // count pin): the ten private collections below emit signalEnvelopes.
    // The AI Inbox collections ride in this domain but are NOT Signal
    // producers — ai_inbox_items is sealed with AES-GCM AIInboxMirrorCodec
    // envelopes and ai_inbox_item_state is intentionally plain status
    // metadata — so they are explicitly declared non-Signal here. Any other
    // unsealed collection added to this domain still fails closed.
    const EXPECTED_SEALED = [
      "conversations", "chat_threads", "mobile_assistant_chats", "cli_sessions",
      "cli_agent_mission_requests", "text_snippets", "rollback_requests",
      "approval_policies", "agent_identities", "subscription_topics",
    ];
    const KNOWN_NON_SIGNAL = new Set([
      "ai_inbox_items",
      "ai_inbox_item_state",
      "burnbar_attachments",
      "mission_approval_answers",
      "mission_approval_ceilings",
    ]);
    const sealedSet = new Set(sealed);
    const missing = EXPECTED_SEALED.filter((c) => !sealedSet.has(c));
    const extra = sealed.filter((c) => !EXPECTED_SEALED.includes(c));
    if (missing.length || extra.length) {
      fail(`conversations_chat must declare Signal producer coverage for exactly the ten private collections (missing: ${missing.join(", ") || "none"}; extra: ${extra.join(", ") || "none"})`);
    }
    const undeclared = [...paths].filter((c) => !sealedSet.has(c) && !KNOWN_NON_SIGNAL.has(c));
    if (undeclared.length) {
      fail(`conversations_chat carries collections that are neither Signal-sealed nor known non-Signal: ${undeclared.join(", ")}`);
    }
  }
}

// (3) No committed Remote Config template may set a Signal flag true.
const SIGNAL_RC_KEYS = /(signal_envelope_v4_enabled|signal_at_rest_[a-z_]+_(enabled|required)|escrow_fingerprint_enforcement)/;
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
  ? "\nactivation parity OK — Signal-capable binaries remain runtime-gated and hard-kill reversible."
  : `\nactivation parity FAILED — ${failures} activation contract(s) drifted.`);
process.exit(failures === 0 ? 0 : 1);
NODE
