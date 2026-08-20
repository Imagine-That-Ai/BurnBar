#!/usr/bin/env bash
# Divergence guard: the accepted RustSec advisory set must live in exactly ONE
# place — crates/openburnbar-iroh/deny.toml. This fails CI if anyone reintroduces
# a hand-maintained --ignore list in the workflow (the drift that this single
# source was created to eliminate), or if the derived set is empty.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SAST_WORKFLOW="${ROOT_DIR}/.github/workflows/rust-sast.yml"
DERIVE="${ROOT_DIR}/scripts/ci/rust-advisory-ignores.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. No hardcoded RustSec ignore literals in the SAST workflow — those must be
#    derived from deny.toml via scripts/ci/rust-advisory-ignores.sh instead.
if grep -nE -- '--ignore[[:space:]]+RUSTSEC' "$SAST_WORKFLOW" >/dev/null 2>&1; then
  echo "Hardcoded advisory ignores found in $(basename "$SAST_WORKFLOW"):" >&2
  grep -nE -- '--ignore[[:space:]]+RUSTSEC' "$SAST_WORKFLOW" >&2
  fail "Move these into crates/openburnbar-iroh/deny.toml and derive them via scripts/ci/rust-advisory-ignores.sh."
fi

# 2. The single source must yield a non-empty, well-formed advisory set.
#    (Portable read loop — avoids `mapfile`, which is absent on bash 3.2.)
IDS=()
while IFS= read -r id; do
  [[ -n "$id" ]] && IDS+=("$id")
done < <(bash "$DERIVE")
[[ "${#IDS[@]}" -gt 0 ]] || fail "deny.toml produced an empty advisory ignore set."
for id in "${IDS[@]}"; do
  [[ "$id" =~ ^RUSTSEC-[0-9]{4}-[0-9]{4}$ ]] || fail "malformed advisory id from deny.toml: '${id}'"
done

# 3. Two readers now derive the accepted-advisory set from deny.toml: this shell
#    helper and scripts/ci/check-cargo-audit-fail-closed.mjs (which the SAST
#    lane actually runs). Two readers of one source is fine; two readers that
#    disagree is the exact drift this guard exists to prevent, so assert they
#    extract the identical set.
NODE_IDS=()
while IFS= read -r id; do
  [[ -n "$id" ]] && NODE_IDS+=("$id")
# Both paths come from ROOT_DIR, never from the caller's cwd. A bare
# `./scripts/...` import resolves against wherever the script was invoked from,
# so running this from /tmp would try to import /tmp/scripts/... and fail —
# while the repo's convention is that these checks work from anywhere.
done < <(ROOT_DIR="$ROOT_DIR" node -e '
const root = process.env.ROOT_DIR;
const { pathToFileURL } = await import("node:url");
const { join } = await import("node:path");
const m = await import(pathToFileURL(join(root, "scripts/ci/check-cargo-audit-fail-closed.mjs")).href);
const { readFileSync } = await import("node:fs");
for (const id of m.acceptedAdvisoryIds(readFileSync(join(root, "crates/openburnbar-iroh/deny.toml"), "utf8"))) {
  console.log(id);
}
' --input-type=module)
if [[ "${IDS[*]}" != "${NODE_IDS[*]}" ]]; then
  echo "Shell derivation: ${IDS[*]}" >&2
  echo "Gate derivation:  ${NODE_IDS[*]}" >&2
  fail "the two deny.toml readers disagree; they must extract the same advisory set."
fi

# 4. The supply-chain policy carries the findings that have NO advisory id
#    (yanked crates, phantom dependencies). It must stay structurally valid and
#    every acceptance must still be time-boxed, or a suppression could rot into
#    permanent blindness.
ROOT_DIR="$ROOT_DIR" node -e '
const root = process.env.ROOT_DIR;
const { pathToFileURL } = await import("node:url");
const { join } = await import("node:path");
import(pathToFileURL(join(root, "scripts/ci/rust-supply-chain-policy.mjs")).href).then((m) => {
  const policy = m.loadPolicy();
  const stale = policy.acceptances.filter((entry) => new Date(entry.expires) <= new Date());
  for (const entry of stale) {
    console.error(`EXPIRED acceptance still committed: ${entry.kind} ${entry.crate} (expired ${entry.expires})`);
  }
  if (stale.length > 0) process.exit(1);
  console.log(`policy OK: ${policy.acceptances.length} time-boxed acceptance(s).`);
});
' --input-type=module || fail "config/rust-supply-chain-policy.json is invalid or carries an expired acceptance."

echo "PASS: advisory ignore set is single-sourced from deny.toml (${#IDS[@]} ids: ${IDS[*]}), both readers agree, and the supply-chain policy is valid."
