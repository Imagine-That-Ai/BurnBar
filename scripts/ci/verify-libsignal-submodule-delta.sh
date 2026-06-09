#!/usr/bin/env bash
#
# Security remediation M-6: verify the Vendor/libsignal git submodule (a personal
# fork, github.com/Ajnunezg/libsignal) diverges from the OFFICIAL signalapp/
# libsignal pinned commit ONLY in allow-listed build-integration files.
#
# The existing verify-libsignal-pin.sh enforces the npm / Maven artifact pins
# (which come straight from Signal), but it does not look at the git submodule.
# This guard closes that gap: if anyone ever lands a change to the crypto core
# (rust/, java/, node/) in the fork, CI fails loudly. A crypto-core divergence
# from official libsignal is a supply-chain red flag and must never ship.
#
# Reads third_party/libsignal/manifest.json:
#   - submoduleFork.basedOnOfficialCommit  (the official commit the fork sits on)
#   - submoduleFork.allowedDivergentFiles  (build files allowed to differ)
#
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

manifest="third_party/libsignal/manifest.json"
submodule="Vendor/libsignal"

read -r official_commit allow_csv < <(python3 - "$manifest" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
fork = m.get("submoduleFork") or {}
official = fork.get("basedOnOfficialCommit", "")
allowed = ",".join(fork.get("allowedDivergentFiles", []))
print(official, allowed)
PY
)

if [[ -z "$official_commit" ]]; then
  echo "ERROR: manifest $manifest is missing submoduleFork.basedOnOfficialCommit" >&2
  exit 1
fi

if [[ ! -e "$submodule/.git" && ! -f "$submodule/.git" ]]; then
  echo "ERROR: submodule $submodule is not checked out. Run: git submodule update --init $submodule" >&2
  exit 1
fi

# The official commit must be reachable in the submodule history. In CI the
# submodule is a shallow clone of the fork; the official commit is its ancestor
# (the fork is official + N build commits), so fetch it if missing.
if ! git -C "$submodule" cat-file -e "${official_commit}^{commit}" 2>/dev/null; then
  echo "Official commit $official_commit not present locally; fetching from upstream signalapp/libsignal..." >&2
  git -C "$submodule" fetch --depth 1 https://github.com/signalapp/libsignal "$official_commit" 2>/dev/null || {
    echo "ERROR: could not fetch official commit $official_commit into $submodule" >&2
    exit 1
  }
fi

changed="$(git -C "$submodule" diff --name-only "${official_commit}..HEAD")"

# Build the allow-list regex from the manifest (exact file paths).
IFS=',' read -r -a allow_arr <<< "$allow_csv"
bad=()
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  ok=0
  for a in "${allow_arr[@]}"; do
    [[ "$f" == "$a" ]] && ok=1 && break
  done
  [[ "$ok" -eq 0 ]] && bad+=("$f")
done <<< "$changed"

if [[ "${#bad[@]}" -gt 0 ]]; then
  echo "ERROR: Vendor/libsignal fork diverges from official $official_commit in NON-allow-listed files:" >&2
  printf '  %s\n' "${bad[@]}" >&2
  echo "" >&2
  echo "Only build-integration files (manifest submoduleFork.allowedDivergentFiles) may differ." >&2
  echo "A crypto-core change in the personal libsignal fork is a supply-chain red flag." >&2
  exit 1
fi

echo "OK: Vendor/libsignal fork delta vs official $official_commit is allow-listed (build-only):"
if [[ -z "$changed" ]]; then
  echo "  (submodule is at the official commit; no divergence)"
else
  echo "$changed" | sed 's/^/  /'
fi
