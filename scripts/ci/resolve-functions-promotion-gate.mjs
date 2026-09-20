#!/usr/bin/env node

// Decides whether the production Cloud Functions release must resolve a
// protected domain-core promotion proof.
//
// Background: gen-3 was annulled in #2173, so `resolve-domain-core-activation`
// reports `active: false` and no promotion-proof run ever signed the resulting
// candidate bundle. #2322 taught the native release gate that lane and #2329
// taught hosting (`deploy-hosting.yml`). The Functions lane was never taught,
// so `deploy-production.yml` kept demanding `gh attestation download` for a
// candidate bundle nothing had signed and every tag deploy died on
// `HTTP 404: Not Found (.../attestations/sha256:...)`.
//
// This resolver is deliberately fail-closed:
//   * the activation flag must be exactly "true" or "false";
//   * the rollback profile ALWAYS requires the proof — it is the manual,
//     protected-review profile and must never take the inactive shortcut;
//   * the inactive lane is only available to `public-production` whose every
//     governed domain mode is `legacy`, i.e. a deploy that executes no
//     domain-core code at all.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const PROFILES = new Set(["public-production", "public-production-rollback"]);
const DOMAINS = [
  "quota",
  "cloudVault",
  "cloudVaultRewrap",
  "cloudVaultSearch",
  "hermes",
  "pricing",
];

export const GATE_REASONS = Object.freeze({
  ROLLBACK_PROFILE: "rollback-profile",
  DOMAIN_CORE_ACTIVE: "domain-core-active",
  DOMAIN_CORE_INACTIVE: "domain-core-inactive",
});

function readLegacyOnlyProfile(profilePath) {
  let profile;
  try {
    profile = JSON.parse(readFileSync(profilePath, "utf8"));
  } catch (error) {
    throw new Error(`unable to read Functions profile: ${error.message}`);
  }
  const modes = profile?.modes;
  if (!modes || typeof modes !== "object" || Array.isArray(modes)) {
    throw new Error("Functions profile does not declare domain modes");
  }
  const names = Object.keys(modes).sort();
  if (JSON.stringify(names) !== JSON.stringify([...DOMAINS].sort())) {
    throw new Error("Functions profile modes do not cover every domain");
  }
  const nonLegacy = DOMAINS.filter((domain) => modes[domain] !== "legacy");
  if (nonLegacy.length > 0) {
    throw new Error(
      `inactive domain core cannot ship non-legacy modes: ${nonLegacy.join(", ")}`,
    );
  }
  return profile;
}

export function resolveFunctionsPromotionGate({
  active,
  profile,
  profilePath = null,
}) {
  if (!PROFILES.has(profile)) {
    throw new Error(
      `unknown signed Functions domain-core profile: ${String(profile)}`,
    );
  }
  if (active !== "true" && active !== "false") {
    throw new Error(
      `activation resolver did not report a boolean active flag: ${String(active)}`,
    );
  }
  if (profile === "public-production-rollback") {
    return {
      proofRequired: true,
      domainCoreInactive: false,
      reason: GATE_REASONS.ROLLBACK_PROFILE,
      notice: null,
    };
  }
  if (active === "true") {
    return {
      proofRequired: true,
      domainCoreInactive: false,
      reason: GATE_REASONS.DOMAIN_CORE_ACTIVE,
      notice: null,
    };
  }
  if (profilePath !== null) readLegacyOnlyProfile(profilePath);
  return {
    proofRequired: false,
    domainCoreInactive: true,
    reason: GATE_REASONS.DOMAIN_CORE_INACTIVE,
    notice:
      "Domain core is inactive; production Functions deploy without a protected signer proof.",
  };
}

function argument(argv, flag, fallback) {
  const index = argv.indexOf(flag);
  if (index === -1) return fallback;
  if (argv.indexOf(flag, index + 1) >= 0)
    throw new Error(`${flag} cannot be repeated`);
  const value = argv[index + 1];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

export function run(argv) {
  const allowed = new Set([
    "--active",
    "--profile",
    "--profile-receipt",
    "--format",
  ]);
  for (const flag of argv) {
    if (flag.startsWith("--") && !allowed.has(flag)) {
      throw new Error(`unknown argument: ${flag}`);
    }
  }
  const decision = resolveFunctionsPromotionGate({
    active: argument(argv, "--active"),
    profile: argument(argv, "--profile"),
    profilePath: argument(argv, "--profile-receipt", null),
  });
  const format = argument(argv, "--format", "json");
  // stderr, so `--format github-output` can be redirected straight into
  // $GITHUB_OUTPUT without the annotation contaminating the output file.
  if (decision.notice) process.stderr.write(`::notice::${decision.notice}\n`);
  if (format === "json") {
    process.stdout.write(`${JSON.stringify(decision, null, 2)}\n`);
  } else if (format === "github-output") {
    process.stdout.write(
      [
        `proof_required=${decision.proofRequired}`,
        `domain_core_inactive=${decision.domainCoreInactive}`,
        `gate_reason=${decision.reason}`,
        "",
      ].join("\n"),
    );
  } else {
    throw new Error(`unsupported format: ${format}`);
  }
  return decision;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    run(process.argv.slice(2));
  } catch (error) {
    console.error(
      `::error::${error instanceof Error ? error.message : String(error)}`,
    );
    process.exitCode = 1;
  }
}
