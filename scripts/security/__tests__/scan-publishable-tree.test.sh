#!/usr/bin/env bash
set -euo pipefail

source_root="$(cd "$(dirname "$0")/../../.." && pwd)"
script_under_test="$source_root/scripts/security/scan-publishable-tree.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fixture_root="$tmp_dir/repo"
stub_bin="$tmp_dir/bin"
artifact_dir="$tmp_dir/artifacts"
marker_dir="$tmp_dir/markers"

mkdir -p "$fixture_root/scripts/security" "$fixture_root/--help" "$stub_bin" "$artifact_dir" "$marker_dir"
cp -p -- "$script_under_test" "$fixture_root/scripts/security/scan-publishable-tree.sh"
printf '%s\n' '[allowlist]' > "$fixture_root/.gitleaks.toml"
printf '%s\n' 'fixture checksum' > "$fixture_root/--help/SHA256SUMS"

cat > "$stub_bin/node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF

cat > "$stub_bin/gitleaks" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${PUBLISHABLE_TREE_TEST_MARKER_DIR:?}"
[[ "${1:-}" == "dir" ]]
[[ "${2:-}" == "." ]]
grep -Fxq -- "fixture checksum" "./--help/SHA256SUMS"
touch "$PUBLISHABLE_TREE_TEST_MARKER_DIR/gitleaks"
EOF

cat > "$stub_bin/trufflehog" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${PUBLISHABLE_TREE_TEST_MARKER_DIR:?}"
[[ "${1:-}" == "filesystem" ]]
scan_root="${2:?missing scan root}"
grep -Fxq -- "fixture checksum" "$scan_root/--help/SHA256SUMS"
touch "$PUBLISHABLE_TREE_TEST_MARKER_DIR/trufflehog"
EOF

chmod +x "$stub_bin/node" "$stub_bin/gitleaks" "$stub_bin/trufflehog"

git -C "$fixture_root" init -q
git -C "$fixture_root" add -- .

scan_output="$tmp_dir/scan.log"
(
  cd "$fixture_root"
  PATH="$stub_bin:$PATH" \
    OPENBURNBAR_SECURITY_SCAN_ARTIFACT_DIR="$artifact_dir" \
    PUBLISHABLE_TREE_TEST_MARKER_DIR="$marker_dir" \
    bash scripts/security/scan-publishable-tree.sh
) > "$scan_output"

grep -Fq -- "Publishable-tree secret scan passed." "$scan_output"
[[ -f "$marker_dir/gitleaks" ]]
[[ -f "$marker_dir/trufflehog" ]]

echo "PASS: option-like publishable paths reach both scanner trees"
