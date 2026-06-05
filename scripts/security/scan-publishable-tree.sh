#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

file_list="$tmp_dir/publishable-files.zlist"
scan_root="$tmp_dir/publishable-tree"
gitleaks_config="$repo_root/.gitleaks.toml"
mkdir -p "$scan_root"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "gitleaks is required. Install it with: brew install gitleaks" >&2
  exit 127
fi

if ! command -v trufflehog >/dev/null 2>&1; then
  echo "trufflehog is required. Install it with: brew install trufflehog" >&2
  exit 127
fi

if [[ ! -f "$gitleaks_config" ]]; then
  echo "Missing gitleaks config at $gitleaks_config" >&2
  exit 1
fi

cd "$repo_root"

# Confidentiality guard: block internal-only content (pricing/COGS, GTM strategy,
# open-vuln working notes) before it ships. Complements the secret scans below —
# this catches content that is sensitive but is not a credential.
if command -v node >/dev/null 2>&1; then
  echo "Running confidentiality guard over the tracked tree..."
  node "$repo_root/scripts/security/scan-internal-content.mjs"
else
  echo "node not found — skipping confidentiality guard (install Node to enable)." >&2
fi

git ls-files -z --cached --others --exclude-standard > "$file_list"

file_count="$(tr -cd '\0' < "$file_list" | wc -c | tr -d ' ')"
if [[ "$file_count" == "0" ]]; then
  echo "No publishable files found to scan." >&2
  exit 1
fi

while IFS= read -r -d '' path; do
  mkdir -p "$scan_root/$(dirname "$path")"
  cp -pP "$path" "$scan_root/$path"
done < "$file_list"

echo "Scanning $file_count publishable files with gitleaks..."
(
  cd "$scan_root"
  gitleaks dir . \
    --config "$gitleaks_config" \
    --redact \
    --no-banner \
    --report-format json \
    --report-path "$tmp_dir/gitleaks.json"
)

echo "Scanning $file_count publishable files with trufflehog verified-secret mode..."
set +e
trufflehog filesystem "$scan_root" \
  --only-verified \
  --no-update \
  --json > "$tmp_dir/trufflehog.json"
trufflehog_status=$?
set -e

if [[ "$trufflehog_status" -ne 0 ]]; then
  echo "trufflehog exited with status $trufflehog_status" >&2
  cat "$tmp_dir/trufflehog.json" >&2
  exit "$trufflehog_status"
fi

if [[ -s "$tmp_dir/trufflehog.json" ]]; then
  echo "trufflehog found verified secrets in publishable files:" >&2
  cat "$tmp_dir/trufflehog.json" >&2
  exit 1
fi

echo "Publishable-tree secret scan passed."
