#!/usr/bin/env node
/**
 * Fail-closed dependency-confusion gate for the Rust supply chain.
 *
 * WHY THIS EXISTS (BurnBar, 2026-08-20)
 * -------------------------------------
 * `arrayref` 0.3.5-0.3.9 were yanked from crates.io and 0.3.10 was published
 * declaring a dependency on `proc-macro1` — a name that does not exist on the
 * registry and is one character from the ubiquitous `proc-macro2`. A tiny,
 * stable utility crate does not grow a proc-macro dependency; that is the
 * signature of a compromised publish.
 *
 * cargo-audit, cargo-deny and OSV all sailed straight past it. They answer
 * "does a published advisory match a crate I already resolved?" — and there was
 * no advisory, and we had not resolved it. The only reason 0.3.10 is not
 * dangerous *today* is that `proc-macro1` is unregistered: the moment anybody
 * claims that name, every project that upgraded executes their build script.
 * An unregistered dependency name is a loaded gun, not a broken link.
 *
 * WHAT THIS CHECKS
 * ----------------
 * Everything already in a Cargo.lock is, by definition, resolvable — cargo
 * proved that when it wrote the file. So confusion cannot enter through the
 * pinned set; it enters through the UPGRADE PATH. For every locked crate this
 * gate reads the registry index, looks at the versions NEWER than the one we
 * pin (the ones a `cargo update` would pull), and reports:
 *
 *   1. phantom      — a declared dependency naming a crate that does not exist
 *                     (reported with the near-miss neighbour, when one exists,
 *                     because `proc-macro1` next to `proc-macro2` is not a
 *                     coincidence)
 *   2. missing-pin  — a locked version the registry does not have at all
 *
 * Deliberately NOT reported: name similarity between crates that both exist.
 * h2/h3 are both official hyper crates and wat/want are unrelated real
 * projects, so edit distance over published names is nearly pure noise — and a
 * gate that cries wolf gets muted. Non-existence is the signal that cannot be
 * argued with.
 *
 * Findings are advisory-free by construction: they describe registry facts, so
 * they land before anyone writes a CVE, which is the entire point.
 *
 * FAILURE POSTURE
 * ---------------
 * Fail closed. A network error is retried and then fails the gate rather than
 * passing silently, because "I could not check" and "I checked and it is clean"
 * must never look the same. Acceptances are time-boxed in
 * config/rust-supply-chain-policy.json and expire on their own.
 */

import { readFileSync, readdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { applyPolicy, loadPolicy } from "./rust-supply-chain-policy.mjs";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SPARSE_INDEX = "https://index.crates.io";

/**
 * crates.io sparse-index path sharding. 1-3 character names live under a
 * numeric prefix; everything else shards on the first two pairs of characters.
 * Names are lowercased because the index is case-insensitive but path-sensitive.
 */
export function indexPathFor(name) {
  const lower = name.toLowerCase();
  if (lower.length === 1) return `1/${lower}`;
  if (lower.length === 2) return `2/${lower}`;
  if (lower.length === 3) return `3/${lower[0]}/${lower}`;
  return `${lower.slice(0, 2)}/${lower.slice(2, 4)}/${lower}`;
}

/**
 * Minimal Cargo.lock reader.
 *
 * Deliberately not a full TOML parse: Cargo.lock is a generated file with a
 * fixed `[[package]]` shape, and a hand-rolled reader has no dependency of its
 * own — which matters for a script whose whole job is distrusting dependencies.
 */
export function parseCargoLock(text) {
  const packages = [];
  let current = null;
  for (const rawLine of text.split("\n")) {
    const line = rawLine.trim();
    if (line === "[[package]]") {
      if (current?.name) packages.push(current);
      current = {};
      continue;
    }
    if (line.startsWith("[") && line !== "[[package]]") {
      if (current?.name) packages.push(current);
      current = null;
      continue;
    }
    if (!current) continue;
    const match = /^(name|version|source)\s*=\s*"([^"]*)"$/u.exec(line);
    if (match) current[match[1]] = match[2];
  }
  if (current?.name) packages.push(current);
  // Workspace members and git/path dependencies carry no `registry+` source.
  // They are ours, they are not fetched by name, and asking the registry about
  // them only manufactures false "this crate does not exist" findings.
  return packages.filter(
    (entry) => entry.name && entry.version && (entry.source ?? "").startsWith("registry+"),
  );
}

/**
 * The registry name behind a dependency entry.
 *
 * Cargo lets a crate rename a dependency — `rand_0_9 = { package = "rand" }` —
 * and the index records the LOCAL ALIAS in `name` with the real crate in
 * `package`. Reading `name` makes every renamed dependency look like a crate
 * that does not exist, which is the single largest source of false positives
 * this gate can produce. Always resolve through `package` first.
 */
export function dependencyCrateName(dependency) {
  const resolved = dependency.package ?? dependency.name;
  return String(resolved).toLowerCase();
}

/** Semver comparison sufficient for ordering registry versions (x.y.z[-pre]). */
export function compareVersions(a, b) {
  const parse = (value) => {
    const [core, pre] = String(value).split("-", 2);
    const parts = core.split(".").map((part) => Number.parseInt(part, 10) || 0);
    return { parts, pre: pre ?? null };
  };
  const left = parse(a);
  const right = parse(b);
  for (let index = 0; index < 3; index += 1) {
    const diff = (left.parts[index] ?? 0) - (right.parts[index] ?? 0);
    if (diff !== 0) return diff < 0 ? -1 : 1;
  }
  // A prerelease sorts below its own release (1.0.0-rc < 1.0.0).
  if (left.pre === right.pre) return 0;
  if (left.pre === null) return 1;
  if (right.pre === null) return -1;
  return left.pre < right.pre ? -1 : 1;
}

/** Damerau-style edit distance, capped — we only ever care about "is it 1?". */
export function editDistance(a, b) {
  if (a === b) return 0;
  if (Math.abs(a.length - b.length) > 1) return 2;
  let previous = Array.from({ length: b.length + 1 }, (_, index) => index);
  for (let i = 1; i <= a.length; i += 1) {
    const current = [i];
    for (let j = 1; j <= b.length; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      current[j] = Math.min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost);
    }
    previous = current;
  }
  return previous[b.length];
}

/**
 * Names that differ only by separator (`serde_json` vs `serde-json`) are the
 * classic registry confusion pair and edit distance treats them as distance 1,
 * so they fall out of the same check.
 */
export function isNearMiss(candidate, known) {
  if (candidate === known) return false;
  return editDistance(candidate, known) === 1;
}

async function fetchIndexEntry(name, { fetchImpl = fetch, retries = 3 } = {}) {
  const url = `${SPARSE_INDEX}/${indexPathFor(name)}`;
  let lastError;
  for (let attempt = 1; attempt <= retries; attempt += 1) {
    try {
      const response = await fetchImpl(url, { redirect: "follow" });
      if (response.status === 404) return { exists: false, versions: [] };
      if (!response.ok) {
        lastError = new Error(`registry returned HTTP ${response.status} for ${name}`);
      } else {
        const body = await response.text();
        const versions = body
          .split("\n")
          .filter((line) => line.trim())
          .map((line) => JSON.parse(line));
        return { exists: true, versions };
      }
    } catch (error) {
      lastError = error;
    }
    if (attempt < retries) {
      await new Promise((resolve) => setTimeout(resolve, attempt * 250));
    }
  }
  // Never downgrade "could not check" into "clean".
  throw new Error(`unable to read the registry index for '${name}': ${lastError?.message ?? "unknown"}`);
}

/**
 * Core analysis. Pure apart from the injected registry reader, so the tests can
 * drive the exact attack shapes without touching the network.
 */
export async function analyzeLock({ packages, readIndex, now = new Date() }) {
  const findings = [];
  const lockedNames = new Set(packages.map((entry) => entry.name.toLowerCase()));
  // A dependency we already resolve is proof-of-existence; never re-look it up.
  const knownExists = new Map([...lockedNames].map((name) => [name, true]));
  const candidateNames = new Map();

  for (const entry of packages) {
    const index = await readIndex(entry.name);
    if (!index.exists) {
      findings.push({
        kind: "missing-pin",
        crate: entry.name,
        version: entry.version,
        detail: `Cargo.lock pins ${entry.name} ${entry.version} but the registry has no such crate.`,
      });
      continue;
    }
    const known = new Set(index.versions.map((version) => version.vers));
    if (!known.has(entry.version)) {
      findings.push({
        kind: "missing-pin",
        crate: entry.name,
        version: entry.version,
        detail: `Cargo.lock pins ${entry.name} ${entry.version}, absent from the registry index.`,
      });
    }

    // The upgrade path: only versions ABOVE what we pin can introduce a name
    // cargo has not already proven resolvable.
    for (const version of index.versions) {
      if (compareVersions(version.vers, entry.version) <= 0) continue;
      if (version.yanked) continue;
      for (const dependency of version.deps ?? []) {
        // Dev-dependencies never reach a consumer's build graph.
        if (dependency.kind === "dev") continue;
        const depName = dependencyCrateName(dependency);
        if (knownExists.has(depName)) continue;
        if (!candidateNames.has(depName)) candidateNames.set(depName, []);
        candidateNames.get(depName).push({
          crate: entry.name,
          pinned: entry.version,
          offeredIn: version.vers,
        });
      }
    }
  }

  for (const [depName, sightings] of candidateNames) {
    const index = await readIndex(depName);
    knownExists.set(depName, index.exists);
    const first = sightings[0];
    if (!index.exists) {
      const neighbour = [...lockedNames].find((known) => isNearMiss(depName, known));
      findings.push({
        kind: "phantom",
        crate: first.crate,
        version: first.offeredIn,
        dependency: depName,
        neighbour: neighbour ?? null,
        detail:
          `${first.crate} ${first.offeredIn} (we pin ${first.pinned}) declares a dependency on ` +
          `'${depName}', which does not exist on the registry` +
          (neighbour
            ? ` and is one edit from '${neighbour}', a crate we already depend on.`
            : ". An unregistered dependency name is claimable by anyone."),
      });
      continue;
    }
    // A dependency that EXISTS is deliberately not flagged on name similarity
    // alone. Real registries are full of legitimate one-edit neighbours — h2/h3
    // are both official hyper crates, wat/want and toml_write/toml_writer are
    // unrelated real projects — so an edit-distance rule over published crates
    // is almost pure noise, and a gate that cries wolf gets muted. Existence is
    // the signal that cannot be argued with: the near-miss name is reported
    // above only when nothing is published under it, where the coincidence
    // stops being a coincidence.
  }

  return findings;
}

export function discoverLockfiles(root = REPO_ROOT) {
  const cratesDir = join(root, "crates");
  if (!existsSync(cratesDir)) return [];
  return readdirSync(cratesDir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => join(cratesDir, entry.name, "Cargo.lock"))
    .filter((path) => existsSync(path));
}

async function main() {
  const lockfiles = discoverLockfiles();
  if (lockfiles.length === 0) {
    console.error("ERROR: no crates/*/Cargo.lock found — refusing to report a clean supply chain.");
    process.exit(1);
  }
  const policy = loadPolicy();
  const cache = new Map();
  const readIndex = async (name) => {
    const key = name.toLowerCase();
    if (!cache.has(key)) cache.set(key, await fetchIndexEntry(key));
    return cache.get(key);
  };

  let live = [];
  let accepted = [];
  for (const lockfile of lockfiles) {
    const packages = parseCargoLock(readFileSync(lockfile, "utf8"));
    console.log(`Scanning ${lockfile.replace(`${REPO_ROOT}/`, "")} (${packages.length} crates)…`);
    const findings = await analyzeLock({ packages, readIndex });
    const result = applyPolicy(findings, policy);
    live = live.concat(result.live.map((finding) => ({ ...finding, lockfile })));
    accepted = accepted.concat(result.accepted);
  }

  for (const { finding, acceptance } of accepted) {
    console.log(`ACCEPTED (${finding.kind}) ${finding.crate}: ${acceptance.reason} [expires ${acceptance.expires}]`);
  }

  if (live.length > 0) {
    console.error("\nRust dependency-confusion gate FAILED:\n");
    for (const finding of live) {
      console.error(`  [${finding.kind}] ${finding.detail}`);
    }
    console.error(
      "\nDo NOT resolve this by upgrading into the flagged version. See " +
        "docs/RUST_SUPPLY_CHAIN.md for how to triage and, if genuinely benign, " +
        "time-box an acceptance in config/rust-supply-chain-policy.json.",
    );
    process.exit(1);
  }

  console.log(`\nPASS: no phantom or typosquatted dependencies on the upgrade path (${accepted.length} accepted).`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    console.error(`Rust dependency-confusion gate could not complete: ${error.message}`);
    process.exit(1);
  });
}
