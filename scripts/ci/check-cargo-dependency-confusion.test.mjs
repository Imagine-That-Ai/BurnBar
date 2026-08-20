import assert from "node:assert/strict";
import test from "node:test";

import { applyPolicy } from "./rust-supply-chain-policy.mjs";
import {
  analyzeLock,
  compareVersions,
  dependencyCrateName,
  editDistance,
  indexPathFor,
  isNearMiss,
  parseCargoLock,
} from "./check-cargo-dependency-confusion.mjs";

/** Build a fake sparse index so the attack shapes run offline and instantly. */
function registry(entries) {
  return async (name) => {
    const key = name.toLowerCase();
    if (!(key in entries)) return { exists: false, versions: [] };
    return { exists: true, versions: entries[key] };
  };
}

const version = (vers, deps = [], yanked = false) => ({ vers, yanked, deps });
const dep = (name, kind = "normal") => ({ name, kind });

test("sparse index paths shard the way crates.io shards them", () => {
  assert.equal(indexPathFor("a"), "1/a");
  assert.equal(indexPathFor("ab"), "2/ab");
  assert.equal(indexPathFor("abc"), "3/a/abc");
  assert.equal(indexPathFor("arrayref"), "ar/ra/arrayref");
  assert.equal(indexPathFor("proc-macro2"), "pr/oc/proc-macro2");
  // The index is case-insensitive but the path is not.
  assert.equal(indexPathFor("SerdeJSON"), "se/rd/serdejson");
});

test("Cargo.lock parsing keeps registry packages and drops trailing tables", () => {
  const packages = parseCargoLock(`
version = 4

[[package]]
name = "arrayref"
version = "0.3.9"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "76a2e8"

[[package]]
name = "openburnbar-iroh"
version = "0.1.0"

[metadata]
key = "value"
`);
  assert.deepEqual(
    packages.map((entry) => `${entry.name}@${entry.version}`),
    ["arrayref@0.3.9"],
    "only registry-sourced packages survive; the workspace member and [metadata] do not",
  );
});

test("version ordering places prereleases below their release", () => {
  assert.equal(compareVersions("0.3.9", "0.3.10") < 0, true);
  assert.equal(compareVersions("1.0.0", "0.9.9") > 0, true);
  assert.equal(compareVersions("1.0.0", "1.0.0"), 0);
  assert.equal(compareVersions("1.0.0-rc.0", "1.0.0") < 0, true);
});

test("edit distance recognises the separator and digit confusions that matter", () => {
  assert.equal(editDistance("proc-macro1", "proc-macro2"), 1);
  assert.equal(editDistance("serde_json", "serde-json"), 1);
  assert.equal(isNearMiss("proc-macro1", "proc-macro2"), true);
  assert.equal(isNearMiss("proc-macro2", "proc-macro2"), false, "a crate is not its own typosquat");
  assert.equal(isNearMiss("tokio", "serde"), false);
});

test("the real arrayref attack is caught on the upgrade path", async () => {
  // Exactly what crates.io served on 2026-08-20: 0.3.5-0.3.9 yanked, and an
  // unyanked 0.3.10 that reaches for a crate one character from proc-macro2.
  const packages = parseCargoLock(`
[[package]]
name = "arrayref"
version = "0.3.9"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "proc-macro2"
version = "1.0.101"
source = "registry+https://github.com/rust-lang/crates.io-index"
`);
  const findings = await analyzeLock({
    packages,
    readIndex: registry({
      arrayref: [
        version("0.3.9", [dep("quickcheck", "dev")], true),
        version("0.3.10", [dep("proc-macro1"), dep("quickcheck", "dev")]),
      ],
      "proc-macro2": [version("1.0.101")],
      // proc-macro1 is absent — the whole point.
    }),
  });

  assert.equal(findings.length, 1);
  const [finding] = findings;
  assert.equal(finding.kind, "phantom");
  assert.equal(finding.crate, "arrayref");
  assert.equal(finding.version, "0.3.10");
  assert.equal(finding.dependency, "proc-macro1");
  assert.equal(finding.neighbour, "proc-macro2", "the near-miss neighbour makes the intent obvious");
});

test("a clean upgrade path produces no findings", async () => {
  const packages = parseCargoLock(`
[[package]]
name = "serde"
version = "1.0.200"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "serde_derive"
version = "1.0.200"
source = "registry+https://github.com/rust-lang/crates.io-index"
`);
  const findings = await analyzeLock({
    packages,
    readIndex: registry({
      serde: [version("1.0.200"), version("1.0.201", [dep("serde_derive")])],
      serde_derive: [version("1.0.200"), version("1.0.201")],
    }),
  });
  assert.deepEqual(findings, []);
});

test("versions at or below the pin are not scanned — cargo already resolved them", async () => {
  const packages = parseCargoLock(`
[[package]]
name = "arrayref"
version = "0.3.10"
source = "registry+https://github.com/rust-lang/crates.io-index"
`);
  const findings = await analyzeLock({
    packages,
    readIndex: registry({
      arrayref: [version("0.3.10", [dep("proc-macro1")])],
    }),
  });
  // We pin it, so cargo resolved it; a phantom here would have failed the build.
  assert.deepEqual(findings, []);
});

test("yanked candidate versions are skipped — cargo will not resolve into them", async () => {
  const packages = parseCargoLock(`
[[package]]
name = "arrayref"
version = "0.3.4"
source = "registry+https://github.com/rust-lang/crates.io-index"
`);
  const findings = await analyzeLock({
    packages,
    readIndex: registry({
      arrayref: [version("0.3.4"), version("0.3.9", [dep("proc-macro1")], true)],
    }),
  });
  assert.deepEqual(findings, []);
});

test("dev-dependencies of candidate versions never reach a consumer build graph", async () => {
  const packages = parseCargoLock(`
[[package]]
name = "arrayref"
version = "0.3.4"
source = "registry+https://github.com/rust-lang/crates.io-index"
`);
  const findings = await analyzeLock({
    packages,
    readIndex: registry({
      arrayref: [version("0.3.4"), version("0.3.11", [dep("some-dev-only-harness", "dev")])],
    }),
  });
  assert.deepEqual(findings, []);
});

test("a published near-miss dependency is NOT flagged on name similarity alone", async () => {
  // h2/h3 are both official hyper crates; wat/want are unrelated real projects.
  // Flagging published crates on edit distance is nearly pure noise, and a gate
  // that cries wolf gets muted. Existence is the signal that cannot be argued with.
  const packages = parseCargoLock(`
[[package]]
name = "widget"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "h2"
version = "0.4.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
`);
  const findings = await analyzeLock({
    packages,
    readIndex: registry({
      widget: [version("1.0.0"), version("1.1.0", [dep("h3")])],
      h2: [version("0.4.0")],
      h3: [version("0.1.0")],
    }),
  });
  assert.deepEqual(findings, [], "a real published crate is not a typosquat just for being close");
});

test("renamed dependencies resolve through `package`, not the local alias", async () => {
  // Cargo lets a crate write `rand_0_9 = { package = "rand", version = "0.9" }`.
  // The index stores the ALIAS in `name`. Reading `name` would report every
  // renamed dependency in the ecosystem as a nonexistent crate — the single
  // largest false-positive source this gate can have.
  assert.equal(dependencyCrateName({ name: "rand_0_9", package: "rand" }), "rand");
  assert.equal(dependencyCrateName({ name: "serde" }), "serde");

  const packages = parseCargoLock(`
[[package]]
name = "num-bigint"
version = "0.4.6"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "rand"
version = "0.9.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
`);
  const findings = await analyzeLock({
    packages,
    readIndex: registry({
      "num-bigint": [
        version("0.4.6"),
        version("0.5.1", [{ name: "rand_0_9", package: "rand", kind: "normal" }]),
      ],
      rand: [version("0.9.0")],
    }),
  });
  assert.deepEqual(findings, [], "an aliased dependency on a crate we already have is not a phantom");
});

test("workspace and path members are never queried against the registry", async () => {
  // Our own crates have no `registry+` source. Asking crates.io about them
  // manufactures "this crate does not exist" findings for first-party code.
  const packages = parseCargoLock(`
[[package]]
name = "openburnbar-media"
version = "0.1.0"

[[package]]
name = "serde"
version = "1.0.200"
source = "registry+https://github.com/rust-lang/crates.io-index"
`);
  assert.deepEqual(
    packages.map((entry) => entry.name),
    ["serde"],
    "the workspace member is filtered out before any lookup",
  );
  const findings = await analyzeLock({ packages, readIndex: registry({ serde: [version("1.0.200")] }) });
  assert.deepEqual(findings, []);
});

test("a pin the registry does not carry fails as missing-pin", async () => {
  const packages = parseCargoLock(`
[[package]]
name = "ghost-crate"
version = "9.9.9"
source = "registry+https://github.com/rust-lang/crates.io-index"
`);
  const findings = await analyzeLock({ packages, readIndex: registry({}) });
  assert.equal(findings.length, 1);
  assert.equal(findings[0].kind, "missing-pin");
});

test("acceptances silence only the exact finding they name", () => {
  const findings = [
    { kind: "phantom", crate: "arrayref", dependency: "proc-macro1", detail: "d" },
    { kind: "phantom", crate: "other", dependency: "proc-macro1", detail: "d" },
  ];
  const policy = {
    schemaVersion: 1,
    acceptances: [
      {
        kind: "phantom",
        crate: "arrayref",
        dependency: "proc-macro1",
        reason: "known",
        expires: "2099-01-01",
      },
    ],
  };
  const { live, accepted } = applyPolicy(findings, policy, new Date("2026-08-20"));
  assert.equal(accepted.length, 1);
  assert.equal(live.length, 1);
  assert.equal(live[0].crate, "other", "an acceptance must not generalise to another crate");
});

test("an expired acceptance stops silencing and re-reds the gate", () => {
  const findings = [{ kind: "phantom", crate: "arrayref", dependency: "proc-macro1", detail: "d" }];
  const policy = {
    schemaVersion: 1,
    acceptances: [
      {
        kind: "phantom",
        crate: "arrayref",
        dependency: "proc-macro1",
        reason: "known",
        expires: "2026-01-01",
      },
    ],
  };
  const { live, accepted } = applyPolicy(findings, policy, new Date("2026-08-20"));
  assert.equal(accepted.length, 0);
  assert.equal(live.length, 1);
  assert.match(live[0].detail, /acceptance expired/u);
});
