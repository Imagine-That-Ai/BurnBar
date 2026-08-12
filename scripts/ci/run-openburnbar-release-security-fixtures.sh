#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$repo_root"

shell_fixtures=(
  scripts/ci/build-corresponding-source-archive.test.sh
  scripts/ci/upload-openburnbar-mas-and-verify.test.sh
  scripts/ci/verify-openburnbar-development-signing.test.sh
  scripts/ci/verify-openburnbar-direct-release.test.sh
  scripts/ci/verify-openburnbar-mas-artifact.test.sh
  scripts/ci/verify-openburnbar-mas-installed-candidate.test.sh
  scripts/ci/verify-openburnbar-safari-extension.test.sh
  scripts/lib/exact-candidate-git.test.sh
  scripts/lib/googlesignin-macos-compat.test.sh
  scripts/lib/libsignal-swift-compat.test.sh
  scripts/lib/pinned-xcodegen.test.sh
  scripts/lib/resolve-repo-path.test.sh
  scripts/materialize-openburnbar-safari-xcode-project.test.sh
  scripts/provision-openburnbar-safari-development.test.sh
  scripts/update-homebrew.test.sh
)

python_fixtures=(
  scripts/generate-sbom.test.py
  scripts/ci/build-macos-website-release-policy.test.py
  scripts/ci/create-openburnbar-development-receipt.test.py
  scripts/ci/create-openburnbar-direct-release-receipt.test.py
  scripts/ci/select-openburnbar-mas-artifact.test.py
  scripts/ci/verify-openburnbar-mas-app-store-connect.test.py
  scripts/ci/verify-openburnbar-mas-installed-receipt.test.py
  scripts/ci/verify-openburnbar-mas-release-wiring.test.py
  scripts/ci/verify-openburnbar-r2-publication.test.py
  scripts/ci/verify-openburnbar-safari-xcodegen-transition.test.py
  scripts/lib/exclusive_json.test.py
)

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: OpenBurnBar release/security fixtures require macOS command semantics." >&2
  exit 1
fi

for fixture in "${shell_fixtures[@]}"; do
  if [[ ! -f "$fixture" || -L "$fixture" ]]; then
    echo "ERROR: required release/security fixture must be a real file: $fixture" >&2
    exit 1
  fi
  printf '==> %s\n' "$fixture"
  bash "$fixture"
done

for fixture in "${python_fixtures[@]}"; do
  if [[ ! -f "$fixture" || -L "$fixture" ]]; then
    echo "ERROR: required release/security fixture must be a real file: $fixture" >&2
    exit 1
  fi
  printf '==> %s\n' "$fixture"
  python3 "$fixture"
done

fixture_count=$((
  ${#shell_fixtures[@]} + ${#python_fixtures[@]}
))
echo "PASS: $fixture_count OpenBurnBar release/security source-only fixtures passed."
