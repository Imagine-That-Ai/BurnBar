/**
 * Single source of truth for time-boxed Rust supply-chain acceptances.
 *
 * The accepted-ADVISORY set lives in crates/openburnbar-iroh/deny.toml, because
 * cargo-deny reads that file directly and a second copy would drift. But two
 * real findings have no advisory id to ignore:
 *
 *   - a YANKED crate (cargo-audit reports `advisory: null`, so `--ignore <id>`
 *     cannot express it at all)
 *   - a PHANTOM dependency on the upgrade path (a registry fact that predates
 *     anybody writing a CVE — which is the entire point of catching it)
 *
 * Those live here. Every entry is time-boxed: past `expires` the gate goes red
 * again and forces a re-decision, so a suppression cannot quietly rot into
 * permanent blindness. That is the same posture as the npm advisory allowlist
 * in scripts/ci/check-npm-audit-fail-closed.mjs.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const POLICY_RELATIVE_PATH = "config/rust-supply-chain-policy.json";

const REPO_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

/** Finding kinds an acceptance is allowed to silence. */
export const ACCEPTABLE_KINDS = Object.freeze(["yanked", "phantom", "typosquat", "missing-pin"]);

const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/u;

/**
 * Read and structurally validate the policy.
 *
 * Validation is strict and fail-closed: a malformed policy throws rather than
 * degrading to "no acceptances", because a silently-empty policy would turn
 * every accepted finding red and tempt whoever is on call to disable the gate.
 */
export function loadPolicy(root = REPO_ROOT) {
  const path = join(root, POLICY_RELATIVE_PATH);
  if (!existsSync(path)) {
    return { schemaVersion: 1, acceptances: [] };
  }
  let policy;
  try {
    policy = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`${POLICY_RELATIVE_PATH} is not valid JSON: ${error.message}`);
  }
  if (policy.schemaVersion !== 1 || !Array.isArray(policy.acceptances)) {
    throw new Error(`${POLICY_RELATIVE_PATH} must declare schemaVersion 1 and an acceptances array`);
  }
  policy.acceptances.forEach((entry, index) => {
    const where = `${POLICY_RELATIVE_PATH} acceptances[${index}]`;
    if (!ACCEPTABLE_KINDS.includes(entry.kind)) {
      throw new Error(`${where}: kind must be one of ${ACCEPTABLE_KINDS.join(", ")}`);
    }
    if (typeof entry.crate !== "string" || entry.crate.length === 0) {
      throw new Error(`${where}: crate is required`);
    }
    // A rationale is mandatory. An acceptance nobody can explain later is
    // indistinguishable from an accident.
    if (typeof entry.reason !== "string" || entry.reason.trim().length < 20) {
      throw new Error(`${where}: reason must be a substantive explanation, not a placeholder`);
    }
    if (typeof entry.expires !== "string" || !ISO_DATE.test(entry.expires)) {
      throw new Error(`${where}: expires must be a YYYY-MM-DD date`);
    }
    // `Date.parse` is not a real-date check: Node silently normalises overflow,
    // so `2026-02-31` becomes March 3 and quietly extends a suppression two days
    // past the date a reviewer signed off on. Round-trip the components instead.
    if (!isRealCalendarDate(entry.expires)) {
      throw new Error(`${where}: expires is not a real date`);
    }
  });
  return policy;
}

/**
 * Find the acceptance covering a finding, if one is live.
 *
 * Matching is exact on every field the acceptance names, so an entry written
 * for one crate can never generalise to another. An acceptance that omits
 * `version` or `dependency` matches any — deliberate, so a yank acceptance can
 * survive a patch bump without going stale on the day it matters most.
 */
export function findAcceptance(finding, policy, now = new Date()) {
  const matches = (policy.acceptances ?? []).filter(
    (entry) =>
      entry.kind === finding.kind &&
      entry.crate.toLowerCase() === String(finding.crate).toLowerCase() &&
      (entry.version === undefined || entry.version === finding.version) &&
      (entry.dependency === undefined ||
        entry.dependency.toLowerCase() === String(finding.dependency ?? "").toLowerCase()),
  );
  if (matches.length === 0) return { status: "unaccepted" };
  // Consider EVERY match before declaring expiry. Taking the first and then
  // checking its date means that when an expired entry is followed by a renewed
  // one for the same crate/version/dependency — which validation permits — the
  // live approval is never seen and the gate stays red until somebody works out
  // that array order decided it.
  const live = matches.filter((entry) => new Date(entry.expires) > now);
  if (live.length > 0) {
    // Latest expiry wins, so a renewal supersedes the entry it replaces rather
    // than depending on where it was appended.
    const acceptance = live.reduce((a, b) => (new Date(b.expires) > new Date(a.expires) ? b : a));
    return { status: "accepted", acceptance };
  }
  const acceptance = matches.reduce((a, b) => (new Date(b.expires) > new Date(a.expires) ? b : a));
  return { status: "expired", acceptance };
}

/**
 * True only when `value` is a date that actually exists.
 *
 * `Date.parse("2026-02-31")` succeeds and normalises to March 3, so the regex
 * plus `Date.parse` pair this replaces would accept a typo and silently grant a
 * longer suppression than anyone approved.
 */
export function isRealCalendarDate(value) {
  const [year, month, day] = String(value).split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year &&
    date.getUTCMonth() === month - 1 &&
    date.getUTCDate() === day
  );
}

/** Split findings into what still fails and what a live acceptance covers. */
export function applyPolicy(findings, policy, now = new Date()) {
  const live = [];
  const accepted = [];
  for (const finding of findings) {
    const result = findAcceptance(finding, policy, now);
    if (result.status === "accepted") {
      accepted.push({ finding, acceptance: result.acceptance });
      continue;
    }
    if (result.status === "expired") {
      live.push({
        ...finding,
        detail: `${finding.detail} — its acceptance expired on ${result.acceptance.expires}; re-evaluate rather than extend blindly.`,
      });
      continue;
    }
    live.push(finding);
  }
  return { live, accepted };
}
