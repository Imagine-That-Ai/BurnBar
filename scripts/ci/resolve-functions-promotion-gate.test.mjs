import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  GATE_REASONS,
  resolveFunctionsPromotionGate,
  run,
} from "./resolve-functions-promotion-gate.mjs";

const SCRIPT = resolve(
  dirname(fileURLToPath(import.meta.url)),
  "resolve-functions-promotion-gate.mjs",
);
const DOMAINS = [
  "quota",
  "cloudVault",
  "cloudVaultRewrap",
  "cloudVaultSearch",
  "hermes",
  "pricing",
];

function profileFile(directory, { name = "public-production", pricing = "legacy" } = {}) {
  const path = join(directory, "profile.json");
  writeFileSync(
    path,
    `${JSON.stringify({
      schemaVersion: 1,
      name,
      artifactAuthority: "signed",
      distribution: "public",
      rolloutChannel: null,
      evidenceEnabled: false,
      modes: Object.fromEntries(
        DOMAINS.map((domain) => [
          domain,
          domain === "pricing" ? pricing : "legacy",
        ]),
      ),
      candidateIdentity: {
        candidateCommit: "a".repeat(40),
        coreVersion: "0.1.0",
        abiVersion: 3,
        sourceSha256: "b".repeat(64),
      },
    })}\n`,
  );
  return path;
}

function withWorkspace(body) {
  const directory = mkdtempSync(join(tmpdir(), "functions-promotion-gate-"));
  try {
    return body(directory);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

// ---------------------------------------------------------------------------
// The release matrix this gate exists to decide. Each case names the real
// situation it stands for, so a future edit that flips one is obvious.
// ---------------------------------------------------------------------------

test("legitimate promotion: an active domain core still requires the protected proof", () => {
  const decision = resolveFunctionsPromotionGate({
    active: "true",
    profile: "public-production",
  });
  assert.deepEqual(decision, {
    proofRequired: true,
    domainCoreInactive: false,
    reason: GATE_REASONS.DOMAIN_CORE_ACTIVE,
    notice: null,
  });
});

test("exact rollback: the protected rollback profile always requires the proof", () => {
  for (const active of ["true", "false"]) {
    const decision = resolveFunctionsPromotionGate({
      active,
      profile: "public-production-rollback",
    });
    assert.equal(decision.proofRequired, true);
    assert.equal(decision.domainCoreInactive, false);
    assert.equal(decision.reason, GATE_REASONS.ROLLBACK_PROFILE);
  }
});

test("illegitimate: the rollback profile cannot take the inactive shortcut even with a legacy profile", () => {
  withWorkspace((directory) => {
    const decision = resolveFunctionsPromotionGate({
      active: "false",
      profile: "public-production-rollback",
      profilePath: profileFile(directory, {
        name: "public-production-rollback",
      }),
    });
    assert.equal(decision.proofRequired, true);
  });
});

test("illegitimate: an inactive claim over a non-legacy profile fails closed", () => {
  withWorkspace((directory) => {
    assert.throws(
      () =>
        resolveFunctionsPromotionGate({
          active: "false",
          profile: "public-production",
          profilePath: profileFile(directory, { pricing: "rust" }),
        }),
      /inactive domain core cannot ship non-legacy modes: pricing/u,
    );
  });
});

test("illegitimate: a non-boolean activation flag fails closed rather than skipping the proof", () => {
  for (const active of ["", "TRUE", "1", undefined, null, "yes"]) {
    assert.throws(
      () =>
        resolveFunctionsPromotionGate({
          active,
          profile: "public-production",
        }),
      /did not report a boolean active flag/u,
    );
  }
});

test("illegitimate: an unknown profile fails closed", () => {
  assert.throws(
    () =>
      resolveFunctionsPromotionGate({
        active: "false",
        profile: "internal",
      }),
    /unknown signed Functions domain-core profile/u,
  );
});

test("illegitimate: a profile missing a governed domain fails closed", () => {
  withWorkspace((directory) => {
    const path = join(directory, "profile.json");
    writeFileSync(path, `${JSON.stringify({ modes: { pricing: "legacy" } })}\n`);
    assert.throws(
      () =>
        resolveFunctionsPromotionGate({
          active: "false",
          profile: "public-production",
          profilePath: path,
        }),
      /modes do not cover every domain/u,
    );
  });
});

// The three tag pushes named in the outage: v1.0.40+repair.37 (2026-09-01),
// +repair.38 and +repair.39 (2026-09-02). All three resolved activation
// `active=false` for candidate c292cc99 with the default `public-production`
// profile, and all three died on
// `gh attestation download ... HTTP 404 .../attestations/sha256:a2d4583c...`.
test("the three real failing release tags resolve to the inactive lane", () => {
  withWorkspace((directory) => {
    const profilePath = profileFile(directory);
    for (const tag of [
      "v1.0.40+repair.37",
      "v1.0.40+repair.38",
      "v1.0.40+repair.39",
    ]) {
      const decision = resolveFunctionsPromotionGate({
        active: "false",
        profile: "public-production",
        profilePath,
      });
      assert.equal(
        decision.proofRequired,
        false,
        `${tag} must no longer demand an unmintable promotion proof`,
      );
      assert.equal(decision.domainCoreInactive, true, tag);
      assert.equal(decision.reason, GATE_REASONS.DOMAIN_CORE_INACTIVE, tag);
      assert.match(decision.notice, /Domain core is inactive/u);
    }
  });
});

test("github-output format carries only key=value pairs", () => {
  withWorkspace((directory) => {
    const stdout = execFileSync(
      process.execPath,
      [
        SCRIPT,
        "--active",
        "false",
        "--profile",
        "public-production",
        "--profile-receipt",
        profileFile(directory),
        "--format",
        "github-output",
      ],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    assert.equal(
      stdout,
      "proof_required=false\ndomain_core_inactive=true\ngate_reason=domain-core-inactive\n",
    );
  });
});

test("the CLI fails closed and annotates when the activation flag is unusable", () => {
  assert.throws(
    () =>
      execFileSync(
        process.execPath,
        [SCRIPT, "--active", "maybe", "--profile", "public-production"],
        { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
      ),
    (error) => {
      assert.notEqual(error.status, 0);
      assert.match(error.stderr, /::error::.*boolean active flag/u);
      return true;
    },
  );
});

test("unknown arguments are rejected", () => {
  assert.throws(
    () => run(["--active", "false", "--profile", "public-production", "--force"]),
    /unknown argument: --force/u,
  );
});
