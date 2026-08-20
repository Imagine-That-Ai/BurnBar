#!/usr/bin/env node
/**
 * Fail-closed cargo-audit gate.
 *
 * WHY NOT `cargo audit --deny warnings --ignore <id>`
 * ---------------------------------------------------
 * `--deny warnings` is the right posture — it escalates unmaintained and yanked
 * crates, not just vulnerabilities — but its only escape hatch is `--ignore`,
 * which takes a RustSec advisory id. A YANKED crate has no advisory id at all;
 * cargo-audit reports it with `advisory: null`. So the moment a dependency is
 * yanked with no upgrade path, the lane is permanently red and the only ways
 * out are to drop `--deny warnings` (which also stops failing on unmaintained
 * advisories — a real loss of signal) or to disable the job.
 *
 * That is a false choice, and BurnBar hit it on 2026-08-20 when `arrayref`
 * 0.3.5-0.3.9 were yanked while `blake3` still required `^0.3.5`, leaving no
 * safe version to move to.
 *
 * This gate keeps the strict posture and adds the missing granularity: every
 * vulnerability fails, every warning fails, EXCEPT ones covered by a live,
 * time-boxed, rationale-carrying acceptance. Advisory acceptances still come
 * from crates/openburnbar-iroh/deny.toml (the existing single source, shared
 * with cargo-deny); yank acceptances come from the supply-chain policy, because
 * deny.toml has nowhere to put them.
 *
 * Execution failures are failures. A database that will not load, a crash, or
 * output that is not JSON all exit non-zero — "I could not check" must never
 * render the same as "I checked and it is clean".
 *
 * Usage: check-cargo-audit-fail-closed.mjs <crate-dir> [-- extra cargo-audit args]
 */

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

import { applyPolicy, loadPolicy } from "./rust-supply-chain-policy.mjs";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const DENY_TOML = join(REPO_ROOT, "crates", "openburnbar-iroh", "deny.toml");

/**
 * Accepted advisory ids, read from the same deny.toml that cargo-deny reads.
 * Kept as a text scan rather than a TOML dependency so this gate has no
 * third-party code of its own.
 */
export function acceptedAdvisoryIds(tomlText) {
  const block = /\[advisories\][\s\S]*?ignore\s*=\s*\[([\s\S]*?)\]/u.exec(tomlText);
  if (!block) return [];
  return [...block[1].matchAll(/"(RUSTSEC-\d{4}-\d{4})"/gu)].map((match) => match[1]);
}

/**
 * Flatten `cargo audit --json` into findings this gate can reason about.
 *
 * Real shape (cargo-audit 0.22.2):
 *   vulnerabilities: { found, count, list: [{ advisory: {id}, package: {name,version} }] }
 *   warnings: { <kind>: [{ kind, package: {name,version}, advisory: {id} | null }] }
 */
export function collectFindings(report) {
  const findings = [];
  for (const entry of report?.vulnerabilities?.list ?? []) {
    findings.push({
      severity: "vulnerability",
      kind: "vulnerability",
      advisoryId: entry.advisory?.id ?? null,
      crate: entry.package?.name,
      version: entry.package?.version,
      detail:
        `${entry.package?.name} ${entry.package?.version}: ${entry.advisory?.id ?? "unknown advisory"} ` +
        `${entry.advisory?.title ?? ""}`.trim(),
    });
  }
  for (const [kind, entries] of Object.entries(report?.warnings ?? {})) {
    for (const entry of entries ?? []) {
      findings.push({
        severity: "warning",
        kind: entry.kind ?? kind,
        advisoryId: entry.advisory?.id ?? null,
        crate: entry.package?.name,
        version: entry.package?.version,
        detail:
          `${entry.package?.name} ${entry.package?.version}: ${kind}` +
          (entry.advisory?.id ? ` (${entry.advisory.id})` : ""),
      });
    }
  }
  return findings;
}

/**
 * Decide the gate.
 *
 * A vulnerability is never acceptable here — those go through deny.toml with
 * cargo-deny and a human, not through a local allowlist.
 */
export function evaluate(findings, { advisoryIds, policy, now = new Date() }) {
  const accepted = [];
  const remaining = [];
  const vulnerabilities = [];
  for (const finding of findings) {
    // Vulnerabilities never reach the policy. loadPolicy() already refuses a
    // "vulnerability" acceptance, but this gate must not depend on validation
    // elsewhere to keep an RCE from being allowlisted — belt and braces on the
    // one class where being wrong is unrecoverable.
    if (finding.severity === "vulnerability") {
      vulnerabilities.push(finding);
      continue;
    }
    if (finding.advisoryId && advisoryIds.includes(finding.advisoryId)) {
      accepted.push({ finding, reason: `accepted advisory ${finding.advisoryId} (deny.toml)` });
      continue;
    }
    remaining.push(finding);
  }
  const { live: liveWarnings, accepted: policyAccepted } = applyPolicy(remaining, policy, now);
  const live = [...vulnerabilities, ...liveWarnings];
  for (const entry of policyAccepted) {
    accepted.push({ finding: entry.finding, reason: `${entry.acceptance.reason} [expires ${entry.acceptance.expires}]` });
  }
  return { live, accepted };
}

function runAudit(crateDir, extraArgs) {
  const result = spawnSync("cargo", ["audit", "--json", ...extraArgs], {
    cwd: crateDir,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) {
    throw new Error(`could not run cargo audit: ${result.error.message}`);
  }
  const stdout = (result.stdout ?? "").trim();
  if (!stdout) {
    throw new Error(
      `cargo audit produced no JSON (exit ${result.status}). stderr:\n${(result.stderr ?? "").trim()}`,
    );
  }
  try {
    return JSON.parse(stdout);
  } catch (error) {
    throw new Error(
      `cargo audit output was not JSON (exit ${result.status}): ${error.message}\n` +
        `stderr:\n${(result.stderr ?? "").trim()}`,
    );
  }
}

function main() {
  const separator = process.argv.indexOf("--");
  const positional = process.argv.slice(2, separator === -1 ? undefined : separator);
  const extraArgs = separator === -1 ? [] : process.argv.slice(separator + 1);
  const crateDir = positional[0];
  if (!crateDir || !existsSync(join(crateDir, "Cargo.lock"))) {
    console.error(`ERROR: expected a crate directory containing Cargo.lock, got '${crateDir ?? ""}'`);
    process.exit(1);
  }

  const advisoryIds = existsSync(DENY_TOML) ? acceptedAdvisoryIds(readFileSync(DENY_TOML, "utf8")) : [];
  if (advisoryIds.length === 0) {
    console.error("ERROR: derived an empty accepted-advisory set from deny.toml — refusing to run half-blind.");
    process.exit(1);
  }
  const policy = loadPolicy();

  const report = runAudit(crateDir, extraArgs);
  const findings = collectFindings(report);
  const { live, accepted } = evaluate(findings, { advisoryIds, policy });

  console.log(`cargo audit: ${crateDir} — ${findings.length} finding(s), ${accepted.length} accepted.`);
  for (const entry of accepted) {
    console.log(`  ACCEPTED [${entry.finding.kind}] ${entry.finding.detail} — ${entry.reason}`);
  }
  if (live.length > 0) {
    console.error(`\ncargo audit gate FAILED for ${crateDir}:\n`);
    for (const finding of live) {
      console.error(`  [${finding.severity}/${finding.kind}] ${finding.detail}`);
    }
    console.error(
      "\nAdvisories are accepted in crates/openburnbar-iroh/deny.toml (with rationale).\n" +
        "Yanked crates with no upgrade path are time-boxed in config/rust-supply-chain-policy.json.\n" +
        "See docs/RUST_SUPPLY_CHAIN.md before accepting anything.",
    );
    process.exit(1);
  }
  console.log(`PASS: no unaccepted advisories or warnings in ${crateDir}.`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  try {
    main();
  } catch (error) {
    // Fail closed: an audit that could not complete is not an audit that passed.
    console.error(`cargo audit gate could not complete: ${error.message}`);
    process.exit(1);
  }
}
