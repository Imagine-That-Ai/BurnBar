#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

file_list="$tmp_dir/publishable-files.zlist"
scan_root="$tmp_dir/publishable-tree"
gitleaks_scan_root="$tmp_dir/gitleaks-text-tree"
gitleaks_config="$repo_root/.gitleaks.toml"
artifact_dir="${OPENBURNBAR_SECURITY_SCAN_ARTIFACT_DIR:-$repo_root/.derived-data/security}"
gitleaks_report="$artifact_dir/gitleaks-publishable-tree.json"
trufflehog_report="$artifact_dir/trufflehog-publishable-tree.jsonl"
mkdir -p "$scan_root" "$gitleaks_scan_root" "$artifact_dir"
rm -f "$gitleaks_report" "$trufflehog_report"

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
  echo "Running known vulnerable dependency floor guard over lockfiles..."
  node "$repo_root/scripts/security/check-known-vulnerability-floors.mjs"
else
  echo "node not found — skipping confidentiality and dependency-floor guards (install Node to enable)." >&2
fi

git ls-files -z --cached --others --exclude-standard > "$file_list"

entry_count="$(tr -cd '\0' < "$file_list" | wc -c | tr -d ' ')"
if [[ "$entry_count" == "0" ]]; then
  echo "No publishable files found to scan." >&2
  exit 1
fi

is_gitlink() {
  local path="$1"
  local mode
  [[ -d "$path" && ! -L "$path" ]] || return 1
  mode="$(git ls-files -s -- "$path" | awk 'NR == 1 { print $1 }')"
  [[ "$mode" == "160000" ]]
}

is_gitleaks_scan_candidate() {
  local path="$1"
  [[ -f "$path" ]] || return 1

  case "$path" in
    *.7z|*.a|*.aar|*.bin|*.bmp|*.car|*.dylib|*.gif|*.gz|*.heic|*.icns|*.ico|*.jar|*.jpeg|*.jpg|*.mov|*.mp4|*.o|*.pdf|*.png|*.so|*.tar|*.tgz|*.ttf|*.wasm|*.webp|*.woff|*.woff2|*.xcframework|*.xz|*.zip)
      return 1
      ;;
  esac

  local mime
  mime="$(/usr/bin/file -b --mime-type "$path" 2>/dev/null || true)"
  case "$mime" in
    text/*|application/json|application/json-seq|application/ld+json|application/javascript|application/x-javascript|application/xml|application/x-empty|application/x-httpd-php|application/x-ndjson|application/x-perl|application/x-php|application/x-python|application/x-ruby|application/x-sh|application/x-shellscript|application/x-toml|application/x-yaml|application/yaml|inode/x-empty)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

copied_file_count=0
gitleaks_file_count=0

copy_publishable_file() {
  local src="$1"
  local rel="$2"

  mkdir -p "$scan_root/$(dirname "$rel")"
  cp -pP "$src" "$scan_root/$rel"
  copied_file_count=$((copied_file_count + 1))

  if is_gitleaks_scan_candidate "$src"; then
    mkdir -p "$gitleaks_scan_root/$(dirname "$rel")"
    cp -pP "$src" "$gitleaks_scan_root/$rel"
    gitleaks_file_count=$((gitleaks_file_count + 1))
  fi
}

while IFS= read -r -d '' path; do
  if is_gitlink "$path"; then
    while IFS= read -r -d '' subpath; do
      copy_publishable_file "$path/$subpath" "$path/$subpath"
    done < <(git -C "$path" ls-files -z --cached)
  elif [[ -d "$path" && ! -L "$path" ]]; then
    while IFS= read -r -d '' child; do
      copy_publishable_file "$child" "$child"
    done < <(find "$path" -type f ! -path '*/.git/*' -print0)
  else
    copy_publishable_file "$path" "$path"
  fi
done < "$file_list"

if [[ "$copied_file_count" == "0" ]]; then
  echo "No publishable file contents found to scan." >&2
  exit 1
fi

if [[ "$gitleaks_file_count" == "0" ]]; then
  echo "No text-like publishable files found for gitleaks." >&2
  exit 1
fi

echo "Scanning $gitleaks_file_count text-like publishable files with gitleaks ($entry_count git entr$( [[ "$entry_count" == "1" ]] && echo "y" || echo "ies" ))..."
(
  cd "$gitleaks_scan_root"
  gitleaks dir . \
    --config "$gitleaks_config" \
    --redact \
    --no-banner \
    --report-format json \
    --report-path "$gitleaks_report" \
    --max-target-megabytes 20
)

echo "Scanning $copied_file_count publishable files with trufflehog verified-secret mode..."
set +e
trufflehog filesystem "$scan_root" \
  --only-verified \
  --no-update \
  --json > "$trufflehog_report"
trufflehog_status=$?
set -e

if [[ "$trufflehog_status" -ne 0 ]]; then
  echo "trufflehog exited with status $trufflehog_status" >&2
  cat "$trufflehog_report" >&2
  exit "$trufflehog_status"
fi

if [[ -s "$trufflehog_report" ]]; then
  echo "trufflehog found verified secrets in publishable files:" >&2
  cat "$trufflehog_report" >&2
  exit 1
fi

echo "Publishable-tree secret scan passed. Reports: $gitleaks_report, $trufflehog_report"
