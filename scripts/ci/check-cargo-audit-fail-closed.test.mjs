import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { parseCargoLock } from "./check-cargo-dependency-confusion.mjs";
import { acceptedAdvisoryIds, collectFindings, evaluate } from "./check-cargo-audit-fail-closed.mjs";
import { loadPolicy } from "./rust-supply-chain-policy.mjs";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

/**
 * The exact shape cargo-audit 0.22.2 emits, captured from a real run against
 * crates/openburnbar-iroh on 2026-08-20. The load-bearing detail is that a
 * yanked warning carries `advisory: null` — which is why `--ignore <id>` can
 * never express it and this gate has to exist.
 */
const REAL_REPORT = {
  vulnerabilities: { found: false, count: 0, list: [] },
  warnings: {
    unmaintained: [
      {
        kind: "unmaintained",
        package: { name: "atomic-polyfill", version: "1.0.3" },
        advisory: { id: "RUSTSEC-2023-0089", title: "atomic-polyfill is unmaintained" },
      },
      {
        kind: "unmaintained",
        package: { name: "bincode", version: "1.3.3" },
        advisory: { id: "RUSTSEC-2025-0141", title: "bincode is unmaintained" },
      },
    ],
    yanked: [{ kind: "yanked", package: { name: "arrayref", version: "0.3.9" }, advisory: null }],
  },
};

const ADVISORY_IDS = ["RUSTSEC-2023-0089", "RUSTSEC-2025-0141"];
const NOW = new Date("2026-08-20T00:00:00Z");

const yankPolicy = (overrides = {}) => ({
  schemaVersion: 1,
  acceptances: [
    {
      kind: "yanked",
      crate: "arrayref",
      version: "0.3.9",
      reason: "pinned by checksum with no unyanked version in range; see the policy file for the full rationale",
      expires: "2026-11-20",
      ...overrides,
    },
  ],
});

test("advisory ids are read from the same deny.toml cargo-deny reads", () => {
  const toml = `
[advisories]
yanked = "warn"
ignore = [
  # rationale comment
  "RUSTSEC-2023-0089", # atomic-polyfill is unmaintained
  "RUSTSEC-2025-0141", # bincode is unmaintained
]

[licenses]
allow = ["MIT"]
`;
  assert.deepEqual(acceptedAdvisoryIds(toml), ["RUSTSEC-2023-0089", "RUSTSEC-2025-0141"]);
});

test("advisory ids outside the [advisories] ignore block are not harvested", () => {
  const toml = `
[advisories]
ignore = ["RUSTSEC-2023-0089"]

[bans]
note = "RUSTSEC-9999-9999 mentioned in prose must not become an acceptance"
`;
  assert.deepEqual(acceptedAdvisoryIds(toml), ["RUSTSEC-2023-0089"]);
});

test("the real report flattens into two unmaintained warnings and one yank", () => {
  const findings = collectFindings(REAL_REPORT);
  assert.equal(findings.length, 3);
  const yanked = findings.find((finding) => finding.kind === "yanked");
  assert.equal(yanked.crate, "arrayref");
  assert.equal(yanked.version, "0.3.9");
  assert.equal(yanked.advisoryId, null, "a yank has no advisory id — the whole reason this gate exists");
});

test("accepted advisories pass and the accepted yank passes with it", () => {
  const { live, accepted } = evaluate(collectFindings(REAL_REPORT), {
    advisoryIds: ADVISORY_IDS,
    policy: yankPolicy(),
    now: NOW,
  });
  assert.deepEqual(live, [], "nothing unaccepted remains");
  assert.equal(accepted.length, 3);
});

test("an unaccepted yank fails the gate", () => {
  const { live } = evaluate(collectFindings(REAL_REPORT), {
    advisoryIds: ADVISORY_IDS,
    policy: { schemaVersion: 1, acceptances: [] },
    now: NOW,
  });
  assert.equal(live.length, 1);
  assert.equal(live[0].kind, "yanked");
  assert.equal(live[0].crate, "arrayref");
});

test("an expired yank acceptance re-reds the gate rather than rotting open", () => {
  const { live, accepted } = evaluate(collectFindings(REAL_REPORT), {
    advisoryIds: ADVISORY_IDS,
    policy: yankPolicy({ expires: "2026-01-01" }),
    now: NOW,
  });
  assert.equal(accepted.length, 2, "the two deny.toml advisories still pass");
  assert.equal(live.length, 1);
  assert.match(live[0].detail, /acceptance expired on 2026-01-01/u);
});

test("a yank acceptance for one version does not cover another", () => {
  const bumped = {
    ...REAL_REPORT,
    warnings: {
      yanked: [{ kind: "yanked", package: { name: "arrayref", version: "0.3.8" }, advisory: null }],
    },
  };
  const { live } = evaluate(collectFindings(bumped), {
    advisoryIds: ADVISORY_IDS,
    policy: yankPolicy(),
    now: NOW,
  });
  assert.equal(live.length, 1, "0.3.8 is not covered by an acceptance written for 0.3.9");
});

test("a vulnerability is never silenced by a policy acceptance", () => {
  const report = {
    vulnerabilities: {
      found: true,
      count: 1,
      list: [
        {
          advisory: { id: "RUSTSEC-2026-0001", title: "remote code execution" },
          package: { name: "arrayref", version: "0.3.9" },
        },
      ],
    },
    warnings: {},
  };
  const { live } = evaluate(collectFindings(report), {
    advisoryIds: ADVISORY_IDS,
    // Even a policy naming this exact crate must not silence a vulnerability.
    policy: yankPolicy({ kind: "vulnerability" }),
    now: NOW,
  });
  assert.equal(live.length, 1);
  assert.equal(live[0].severity, "vulnerability");
});

test("an unmaintained advisory that is NOT in deny.toml fails", () => {
  const report = {
    vulnerabilities: { found: false, count: 0, list: [] },
    warnings: {
      unmaintained: [
        {
          kind: "unmaintained",
          package: { name: "brand-new-dep", version: "1.0.0" },
          advisory: { id: "RUSTSEC-2026-9999", title: "unmaintained" },
        },
      ],
    },
  };
  const { live } = evaluate(collectFindings(report), {
    advisoryIds: ADVISORY_IDS,
    policy: yankPolicy(),
    now: NOW,
  });
  assert.equal(live.length, 1);
  assert.equal(live[0].crate, "brand-new-dep");
});

test("the committed policy is valid and currently covers the arrayref yank", () => {
  const policy = loadPolicy();
  const { live, accepted } = evaluate(collectFindings(REAL_REPORT), {
    advisoryIds: ADVISORY_IDS,
    policy,
    now: NOW,
  });
  assert.deepEqual(
    live,
    [],
    "the checked-in config/rust-supply-chain-policy.json must actually cover the yank it was written for",
  );
  assert.ok(
    accepted.some((entry) => entry.finding.kind === "yanked" && /blake3/u.test(entry.reason)),
    "the acceptance rationale should name the blocker that makes it necessary",
  );
});

/**
 * Tony Arcieri yanked der 0.8.0 on 2026-09-05 13:29 UTC. pkcs8 0.11 / spki 0.8
 * already accept ^0.8, and unyanked 0.8.1 has been on crates.io since July.
 * Merge-group cargo-audit fail-closed on the yank and kicked every MQ
 * candidate, including the style-dictionary bump. The real fix is the
 * lockfile pin, not a policy acceptance — this test fails if 0.8.0 comes back.
 */
test("iroh and burnbar-remote lockfiles do not pin yanked der 0.8.0", () => {
  const snippet = `[[package]]
name = "der"
version = "0.8.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
`;
  assert.deepEqual(
    parseCargoLock(snippet).map((entry) => `${entry.name}@${entry.version}`),
    ["der@0.8.0"],
    "the lock parser must actually see a yanked 0.8.0 pin so the live assertion is not a tautology",
  );

  for (const rel of ["crates/openburnbar-iroh/Cargo.lock", "crates/burnbar-remote/Cargo.lock"]) {
    const versions = parseCargoLock(readFileSync(join(REPO_ROOT, rel), "utf8"))
      .filter((entry) => entry.name === "der")
      .map((entry) => entry.version);
    assert.ok(versions.length > 0, `${rel} must lock der`);
    assert.ok(
      !versions.includes("0.8.0"),
      `${rel} still pins yanked der 0.8.0 (${versions.join(", ")}); cargo update -p der@0.8.0 --precise 0.8.1`,
    );
  }
});
