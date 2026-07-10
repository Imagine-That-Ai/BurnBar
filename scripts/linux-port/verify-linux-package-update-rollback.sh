#!/usr/bin/env bash
set -euo pipefail

root="${OB_REPO_ROOT:-/workspace}"
out_dir="${OB_EVIDENCE_OUT:-/workspace/.linux-shard/session}"
candidate="${OB_CANDIDATE_DEB:-}"
previous="${OB_PREVIOUS_DEB:-}"
report="$out_dir/package-update-rollback.json"
log="$out_dir/package-update-rollback.log"
mkdir -p "$out_dir"

write_blocked() {
  local reason="$1"
  REPORT="$report" REASON="$reason" node <<'NODE'
const fs = require('node:fs');
const reason = process.env.REASON;
const lifecycle = Object.fromEntries(['update', 'rollback', 'dataPreservation'].map((key) => [
  key,
  { status: 'blocked', reason }
]));
fs.writeFileSync(process.env.REPORT, `${JSON.stringify({
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  passed: false,
  lifecycle
}, null, 2)}\n`);
NODE
}

if [[ -z "$candidate" || ! -f "$candidate" ]]; then
  echo "Candidate .deb is required" >&2
  exit 1
fi
if [[ -z "$previous" || ! -f "$previous" ]]; then
  reason='No previous same-architecture Linux .deb was supplied; update, rollback, and data-preservation promotion gates remain blocked.'
  write_blocked "$reason"
  printf '%s\n' "$reason" >"$log"
  cat "$report"
  exit 0
fi

exec > >(tee "$log") 2>&1
candidate_pkg="$(dpkg-deb -f "$candidate" Package)"
previous_pkg="$(dpkg-deb -f "$previous" Package)"
candidate_version="$(dpkg-deb -f "$candidate" Version)"
previous_version="$(dpkg-deb -f "$previous" Version)"
if [[ "$candidate_pkg" != "$previous_pkg" ]]; then
  echo "Package identity changed across update: $previous_pkg -> $candidate_pkg" >&2
  exit 1
fi
if ! dpkg --compare-versions "$previous_version" lt "$candidate_version"; then
  echo "Previous version must be older than candidate: $previous_version !< $candidate_version" >&2
  exit 1
fi

work_dir="${OB_UPDATE_WORKDIR:-/tmp/openburnbar-linux-update-rollback}"
rm -rf "$work_dir"
mkdir -p "$work_dir/home/.local/share/openburnbar" "$work_dir/runtime"
chmod 700 "$work_dir/runtime"
sentinel="$work_dir/home/.local/share/openburnbar/parity-update-sentinel.json"
printf '{"preserve":"openburnbar-linux-parity","createdBy":"package-update-rollback"}\n' >"$sentinel"
sentinel_hash="$(sha256sum "$sentinel" | awk '{print $1}')"

probe_installed() {
  local expected="$1"
  local phase="$2"
  local installed
  installed="$(dpkg-query -W -f='${Version}' "$candidate_pkg")"
  test "$installed" = "$expected"
  test "$(sha256sum "$sentinel" | awk '{print $1}')" = "$sentinel_hash"
  gui="$(dpkg -L "$candidate_pkg" | grep -E '/usr/bin/openburnbar-linux-desktop$' | head -n 1)"
  daemon="$(dpkg -L "$candidate_pkg" | grep -E '/usr/bin/openburnbar-daemon$' | head -n 1)"
  test -x "$gui"
  test -x "$daemon"
  "$gui" --version | tee "$out_dir/${phase}-shell-version.txt"
  grep -F "$expected" "$out_dir/${phase}-shell-version.txt" >/dev/null
  HOME="$work_dir/home" XDG_RUNTIME_DIR="$work_dir/runtime" \
    /usr/libexec/openburnbar-daemon-launch --help >"$out_dir/${phase}-daemon-help.txt"
  grep -F 'socket-path' "$out_dir/${phase}-daemon-help.txt" >/dev/null
}

cleanup() {
  dpkg -r "$candidate_pkg" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== install previous $previous_version =="
dpkg -i "$previous"
probe_installed "$previous_version" previous

echo "== update to candidate $candidate_version =="
dpkg -i "$candidate"
probe_installed "$candidate_version" updated

echo "== roll back to previous $previous_version =="
dpkg -i --force-downgrade "$previous"
probe_installed "$previous_version" rolled-back

echo "== restore candidate $candidate_version =="
dpkg -i "$candidate"
probe_installed "$candidate_version" restored-candidate

REPORT="$report" CANDIDATE="$candidate" PREVIOUS="$previous" PACKAGE="$candidate_pkg" CANDIDATE_VERSION="$candidate_version" PREVIOUS_VERSION="$previous_version" SENTINEL="$sentinel" SENTINEL_HASH="$sentinel_hash" node <<'NODE'
const fs = require('node:fs');
const lifecycle = {
  update: { status: 'passed', from: process.env.PREVIOUS_VERSION, to: process.env.CANDIDATE_VERSION },
  rollback: { status: 'passed', from: process.env.CANDIDATE_VERSION, to: process.env.PREVIOUS_VERSION },
  dataPreservation: { status: 'passed', sentinel: process.env.SENTINEL, sha256: process.env.SENTINEL_HASH }
};
fs.writeFileSync(process.env.REPORT, `${JSON.stringify({
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  passed: true,
  package: process.env.PACKAGE,
  candidate: { file: process.env.CANDIDATE, version: process.env.CANDIDATE_VERSION },
  previous: { file: process.env.PREVIOUS, version: process.env.PREVIOUS_VERSION },
  lifecycle
}, null, 2)}\n`);
NODE
cat "$report"
