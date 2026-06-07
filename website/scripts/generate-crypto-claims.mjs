#!/usr/bin/env node
/**
 * generate-crypto-claims.mjs — emits website/src/data/crypto-claims.generated.ts
 *
 * Makes "the encryption claims are checked against the crypto registry" literally true.
 *
 * Inputs (all machine-checked elsewhere in CI):
 *   1. docs/security/crypto-architecture-policy.json — the policy registry that
 *      scripts/ci/check_burnbar_crypto_architecture_policy.py asserts byte-for-byte.
 *   2. packages/libsignal-bridge/package.json — the libsignal pin, which
 *      scripts/ci/check_burnbar_license_posture.py enforces verbatim.
 *   3. third_party/libsignal/runtime-readiness.json — the fail-closed rollout
 *      gate. While it reads "not_ready", the site may say "wired in, not
 *      activated in production". The moment it flips, THIS GENERATOR FAILS,
 *      forcing the copy to be revised before it can ship again. The sentence
 *      cannot outlive the fact.
 *
 * The public lines below are a transform of the registry: model ids, platform
 * cells, invariants, the pin, and the rollout state all come from the inputs;
 * PUBLIC_LINES only contributes plain-language phrasing (exactly like
 * TIER_DISPLAY in packages/data-domains/codegen.mjs holds tier display copy
 * while definitions come from registry.json). Fail-closed checks reject the
 * copy when the registry stops backing it:
 *   - every PUBLIC_LINES model must exist in policy.claims, and vice versa;
 *   - every platform a line names must be present in that model's matrix
 *     cells, and every platform in the cells must be named by the line;
 *   - the iOS libsignal-free invariant must back the iPhone lines;
 *   - the rollout-status phrase may not be hand-typed anywhere in website/src
 *     outside the generated module (pages must interpolate the exported
 *     constant, so a readiness flip forces every occurrence at once).
 *
 * Drift gate: .github/workflows/fast-feedback.yml runs `--check` — the same
 * mechanism that guards trust.generated.ts. Locally: `npm run test:crypto-claims`.
 *
 * Usage:
 *   node website/scripts/generate-crypto-claims.mjs           # write the module
 *   node website/scripts/generate-crypto-claims.mjs --check   # exit 1 on drift
 */

import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(HERE, "..", "..");
const POLICY_PATH = join(REPO_ROOT, "docs", "security", "crypto-architecture-policy.json");
const PIN_PATH = join(REPO_ROOT, "packages", "libsignal-bridge", "package.json");
const READINESS_PATH = join(REPO_ROOT, "third_party", "libsignal", "runtime-readiness.json");
const SRC_ROOT = join(HERE, "..", "src");
const OUT_PATH = join(SRC_ROOT, "data", "crypto-claims.generated.ts");

function fail(message) {
  console.error(`[crypto-claims] FAIL: ${message}`);
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Load + validate the three machine sources (fail closed on every surprise).
// ---------------------------------------------------------------------------

const policy = JSON.parse(readFileSync(POLICY_PATH, "utf8"));
if (policy.schemaVersion !== 1) fail(`unexpected policy schemaVersion ${policy.schemaVersion}`);
if (!policy.claims || typeof policy.claims !== "object") fail("policy.claims missing");
if (!Array.isArray(policy.invariants)) fail("policy.invariants missing");
if (!policy.platforms || typeof policy.platforms !== "object") fail("policy.platforms missing");

const pinPkg = JSON.parse(readFileSync(PIN_PATH, "utf8"));
const libsignalPin = pinPkg?.dependencies?.["@signalapp/libsignal-client"];
if (!/^\d+\.\d+\.\d+$/.test(libsignalPin ?? "")) {
  fail(
    `could not read a plain libsignal pin from ${PIN_PATH} (got ${JSON.stringify(libsignalPin)})`
  );
}

const readiness = JSON.parse(readFileSync(READINESS_PATH, "utf8"));
if (readiness.status !== "not_ready") {
  fail(
    `third_party/libsignal/runtime-readiness.json status is ${JSON.stringify(readiness.status)}, ` +
      `not "not_ready". The "${"wired in, not activated in production"}" copy is no longer true — ` +
      `revise PUBLIC_LINES, LIBSIGNAL_ROLLOUT_STATUS, and CRYPTO_NOT_CLAIMS in this generator ` +
      `before regenerating.`
  );
}

/**
 * The one rollout-posture phrase every page must interpolate (never hand-type).
 * Emitted only while the readiness gate above holds.
 */
const LIBSIGNAL_ROLLOUT_STATUS = "wired in, not activated in production";

// ---------------------------------------------------------------------------
// "Wired in" is evidence-checked, not asserted: the at-rest dual-write code,
// the per-domain kill switch, the rules-layer validator, and the bridge must
// all exist in-tree, or the phrase may not ship.
// ---------------------------------------------------------------------------

const WIRED_IN_EVIDENCE = [
  "AgentLens/Services/MacCloudVaultSignalPayloads.swift",
  "OpenBurnBarMobile/Services/MobileCloudVaultSignalPayloads.swift",
  "android/app/src/main/java/com/openburnbar/data/cloud/AndroidCloudVaultSignalPayloads.kt",
  "functions/src/signalAtRestWrite.ts",
  "packages/libsignal-bridge/src/index.ts"
];
for (const rel of WIRED_IN_EVIDENCE) {
  try {
    readFileSync(join(REPO_ROOT, rel));
  } catch {
    fail(`"${LIBSIGNAL_ROLLOUT_STATUS}" is unbacked: wiring evidence ${rel} is missing`);
  }
}
const macPayloads = readFileSync(join(REPO_ROOT, WIRED_IN_EVIDENCE[0]), "utf8");
if (!macPayloads.includes("signal_at_rest_")) {
  fail('the per-domain kill switch (signal_at_rest_<domain>_enabled) is gone from the Mac writer — "wired in" is unbacked');
}
const rules = readFileSync(join(REPO_ROOT, "firestore.rules"), "utf8");
if (!rules.includes("validSignalAtRestEnvelope")) {
  fail('firestore.rules no longer validates signal at-rest envelopes — "wired in" is unbacked');
}

// ---------------------------------------------------------------------------
// The CryptoKit interop claim is locked by COMMITTED cross-implementation
// vectors (ADR-001 §7.2): the fixture must exist with both directions, the
// Swift suite must consume it, and CI must verify the libsignal side.
// ---------------------------------------------------------------------------

const INTEROP_VECTOR = join(
  REPO_ROOT,
  "OpenBurnBarCore",
  "Tests",
  "OpenBurnBarSignalCoreTests",
  "Fixtures",
  "CryptoKitAtRestInteropVector.json"
);
let interop;
try {
  interop = JSON.parse(readFileSync(INTEROP_VECTOR, "utf8"));
} catch {
  fail("the CryptoKit interop claim is unbacked: committed vector CryptoKitAtRestInteropVector.json is missing");
}
const interopIds = (interop.cases ?? []).map((c) => c.id).sort();
if (
  JSON.stringify(interopIds) !==
  JSON.stringify(["cryptokit-seals-libsignal-opens", "libsignal-seals-cryptokit-opens"])
) {
  fail(`interop vector no longer covers both directions (found: ${interopIds.join(", ")})`);
}
const interopTests = readFileSync(
  join(REPO_ROOT, "OpenBurnBarCore", "Tests", "OpenBurnBarSignalCoreTests", "CryptoKitAtRestInteropTests.swift"),
  "utf8"
);
if (!interopTests.includes("CryptoKitAtRestInteropVector")) {
  fail("CryptoKitAtRestInteropTests.swift no longer exercises the committed interop vector");
}
const fastFeedback = readFileSync(join(REPO_ROOT, ".github", "workflows", "fast-feedback.yml"), "utf8");
if (!fastFeedback.includes("generate-cryptokit-interop-vector.mjs")) {
  fail("CI no longer verifies the committed interop vectors (fast-feedback step missing)");
}

// ---------------------------------------------------------------------------
// The CryptoKit read path requires iOS 17+; the site's stated floor must
// match, or the iPhone lines need the legacy-vault caveat instead.
// ---------------------------------------------------------------------------

const siteTs = readFileSync(join(HERE, "..", "src", "data", "site.ts"), "utf8");
const iosFloor = siteTs.match(/iosMin:\s*"iOS (\d+)"/);
if (!iosFloor || Number(iosFloor[1]) < 17) {
  fail(
    `site iosMin is ${iosFloor ? `iOS ${iosFloor[1]}` : "missing"} — the CryptoKit sealed-envelope ` +
      "read path needs iOS 17+; rewrite the iPhone lines with the legacy-vault caveat before lowering the floor"
  );
}

// ---------------------------------------------------------------------------
// Display phrasing per registry model. Plain language only — no protocol or
// library jargon leaves this file for the page. `platforms` declares which
// matrix platforms the line speaks for; the cross-check below fails closed if
// the declaration, the prose, and the policy matrix ever disagree.
// ---------------------------------------------------------------------------

/** How each policy platform is named in rendered prose. */
const PLATFORM_DISPLAY = {
  macos: "Mac",
  android: "Android",
  daemon: "daemon",
  backend: "backend",
  ios: "iPhone"
};

const ALL_PLATFORMS = Object.keys(policy.platforms).sort();

const PUBLIC_LINES = {
  "libsignal-double-ratchet": {
    platforms: ["macos", "android", "daemon"],
    line:
      "Device-to-device lanes (Mac, Android, daemon) are built on Signal's official open-source " +
      `library, pinned at v${libsignalPin} — wired in today, not yet activated in production; ` +
      "activation comes by staged rollout with instant revert."
  },
  "libsignal-hpke-seal": {
    platforms: ["macos", "android", "daemon", "backend"],
    line:
      "At-rest sealing on Mac, Android, daemon, and backend uses the official Signal library's " +
      `sealed envelopes — ${LIBSIGNAL_ROLLOUT_STATUS}.`
  },
  "cryptokit-hpke-atrest": {
    platforms: ["ios"],
    line:
      "iPhone and iPad read the same sealed envelopes through Apple's CryptoKit — interop with " +
      "the Signal library's seal is locked by committed cross-implementation test vectors in CI, " +
      "with no Signal code in the App Store app."
  },
  "homegrown-double-ratchet": {
    platforms: ALL_PLATFORMS,
    line:
      "Every phone-to-AI-gateway lane runs our own hardened encrypted gateway — forward-secret, " +
      "keys pinned to your devices, downgrade attempts refused outright."
  },
  "none-satellite": {
    platforms: ["ios"],
    line:
      "The iPhone app runs no device-to-device encryption of its own — it is a secure satellite " +
      "that reads what your other devices seal."
  }
};

const policyModels = Object.keys(policy.claims).sort();
const lineModels = Object.keys(PUBLIC_LINES).sort();
if (JSON.stringify(policyModels) !== JSON.stringify(lineModels)) {
  fail(
    `PUBLIC_LINES models drifted from policy.claims.\n  policy: ${policyModels.join(", ")}\n  lines:  ${lineModels.join(", ")}`
  );
}

// Cells where each model is in force, straight from the matrix.
const cellsByModel = {};
const platformsByModel = {};
for (const [platform, channels] of Object.entries(policy.platforms)) {
  for (const [channel, model] of Object.entries(channels)) {
    if (typeof model !== "string" || !(model in policy.claims)) {
      fail(`matrix cell ${platform}.${channel} holds unknown model ${JSON.stringify(model)}`);
    }
    (cellsByModel[model] ??= []).push(`${platform} · ${channel.replaceAll("_", "-")}`);
    (platformsByModel[model] ??= new Set()).add(platform);
  }
}

// Platform-truth check: the platforms a line declares (and names in prose)
// must exactly equal the platforms the policy matrix gives that model. A
// legitimate registry change can therefore never leave stale platform prose
// behind — the generator goes red until the line is rewritten.
for (const [model, spec] of Object.entries(PUBLIC_LINES)) {
  const declared = [...spec.platforms].sort();
  const inMatrix = [...(platformsByModel[model] ?? [])].sort();
  if (JSON.stringify(declared) !== JSON.stringify(inMatrix)) {
    fail(
      `PUBLIC_LINES["${model}"] declares platforms [${declared.join(", ")}] but the policy ` +
        `matrix has it on [${inMatrix.join(", ")}] — rewrite the line to match the registry.`
    );
  }
  for (const platform of declared) {
    const name = PLATFORM_DISPLAY[platform];
    if (!name) fail(`PLATFORM_DISPLAY is missing ${platform}`);
    // The homegrown gateway line speaks of "every phone-to-AI-gateway lane"
    // rather than enumerating; require enumeration only when the line does not
    // cover the full platform set.
    if (declared.length !== ALL_PLATFORMS.length && !spec.line.includes(name)) {
      fail(
        `PUBLIC_LINES["${model}"] is in force on ${platform} but its prose never names ` +
          `"${name}" — the sentence and the matrix must agree.`
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Not-claims. Each line that CAN be machine-backed IS machine-backed.
// ---------------------------------------------------------------------------

const iosInvariantBacked = policy.invariants.some((line) =>
  line.includes("iOS must never map to the 'Signal Protocol' claim")
);
if (!iosInvariantBacked) {
  fail(
    "policy.invariants no longer contains the iOS 'Signal Protocol' prohibition — not-claim #1 is unbacked"
  );
}
const iosModels = Object.values(policy.platforms.ios ?? {});
if (
  iosModels.length === 0 ||
  iosModels.some((m) => String(m).toLowerCase().includes("libsignal"))
) {
  fail(
    "policy.platforms.ios is missing or libsignal-bearing — the libsignal-free iPhone line is unbacked"
  );
}

const CRYPTO_NOT_CLAIMS = [
  "We don't put Signal's library on iPhone or iPad. The App Store app never links it — that is " +
    "an enforced invariant in our crypto registry, not a roadmap item.",
  "We don't claim any Signal-library lane is live in production. It is wired in but off — " +
    "per-domain flags, staged rollout, instant revert. A fail-closed readiness gate keeps this " +
    "sentence honest: when the rollout flips on, this page is forced to change.",
  "We don't claim affiliation or endorsement. Signal Messenger has nothing to do with us — we pin " +
    "their open-source library, and we say so plainly.",
  "We don't claim an external audit. There hasn't been one yet; when there is, it will be linked here."
];

// ---------------------------------------------------------------------------
// Source hygiene: the rollout-status phrase must flow through the exported
// constant — hand-typing it anywhere in website/src (outside this generator's
// output) would let a stale copy of the fact outlive a readiness flip.
// ---------------------------------------------------------------------------

function walk(dir, hits = []) {
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    const st = statSync(p);
    if (st.isDirectory()) walk(p, hits);
    else if (/\.(astro|ts|mjs|js)$/.test(entry)) hits.push(p);
  }
  return hits;
}

const HAND_TYPED_FORBIDDEN = [/not activated in production/i, /wired in,? not activated/i];
for (const file of walk(SRC_ROOT)) {
  if (file === OUT_PATH) continue;
  const text = readFileSync(file, "utf8");
  for (const pattern of HAND_TYPED_FORBIDDEN) {
    if (pattern.test(text)) {
      fail(
        `${file} hand-types the rollout posture (${pattern}). Interpolate ` +
          `LIBSIGNAL_ROLLOUT_STATUS from @data/crypto-claims.generated instead, so a readiness ` +
          `flip updates every occurrence at once.`
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Emit (deterministic — no timestamps, stable ordering).
// ---------------------------------------------------------------------------

const claims = policyModels.map((model) => ({
  model,
  policyClaim: policy.claims[model],
  publicLine: PUBLIC_LINES[model].line,
  cells: (cellsByModel[model] ?? []).sort()
}));

const ts = `// GENERATED by website/scripts/generate-crypto-claims.mjs — DO NOT EDIT.
// Sources: docs/security/crypto-architecture-policy.json (the policy registry),
//          packages/libsignal-bridge/package.json (the CI-enforced libsignal pin),
//          third_party/libsignal/runtime-readiness.json (the fail-closed rollout gate).
//
// burnbar.ai/trust renders its encryption claims from this file. A CI drift
// gate (.github/workflows/fast-feedback.yml: \`--check\` mode) fails if this
// file is stale, missing, or hand-edited — the same mechanism that guards
// trust.generated.ts. The generator also fails closed when the policy matrix
// stops backing a line's platforms, or when the rollout gate flips — so the
// "${LIBSIGNAL_ROLLOUT_STATUS}" framing cannot outlive the rollout it
// describes. Re-generate with: node website/scripts/generate-crypto-claims.mjs

/** Official Signal library version pinned across the repo (CI-enforced byte-for-byte). */
export const LIBSIGNAL_PIN = ${JSON.stringify(libsignalPin)};

/**
 * The rollout posture for every Signal-library lane, emitted only while the
 * fail-closed readiness gate holds. Pages must interpolate this constant —
 * hand-typing the phrase anywhere in website/src fails the generator.
 */
export const LIBSIGNAL_ROLLOUT_STATUS = ${JSON.stringify(LIBSIGNAL_ROLLOUT_STATUS)};

export interface CryptoClaim {
  /** Registry model id (docs/security/crypto-architecture-policy.json). */
  model: string;
  /**
   * Canonical claim vocabulary, verbatim from the policy registry.
   * Internal traceability only — never rendered; render \`publicLine\`.
   */
  policyClaim: string;
  /** Plain-language line rendered on burnbar.ai. Derived by the generator. */
  publicLine: string;
  /** Matrix cells ("platform · channel") where this model is in force. */
  cells: readonly string[];
}

export const CRYPTO_CLAIMS: readonly CryptoClaim[] = ${JSON.stringify(claims, null, 2)} as const;

/**
 * What we deliberately do not claim. Every line that can be machine-backed is
 * machine-backed — the generator fails closed if the registry or the rollout
 * gate stops supporting one.
 */
export const CRYPTO_NOT_CLAIMS: readonly string[] = ${JSON.stringify(CRYPTO_NOT_CLAIMS, null, 2)} as const;
`;

if (process.argv.includes("--check")) {
  let onDisk = null;
  try {
    onDisk = readFileSync(OUT_PATH, "utf8");
  } catch {
    fail(`missing ${OUT_PATH} — run \`node website/scripts/generate-crypto-claims.mjs\``);
  }
  if (onDisk !== ts) {
    fail(
      "website/src/data/crypto-claims.generated.ts is stale — run " +
        "`node website/scripts/generate-crypto-claims.mjs` and commit the result " +
        "(the public crypto copy must equal the policy registry byte-for-byte)."
    );
  }
  console.log("[crypto-claims] OK: generated copy matches the policy registry.");
} else {
  writeFileSync(OUT_PATH, ts);
  console.log(
    `[crypto-claims] generated ${claims.length} claim lines + ${CRYPTO_NOT_CLAIMS.length} not-claims from the policy registry (libsignal pin ${libsignalPin}).`
  );
}
