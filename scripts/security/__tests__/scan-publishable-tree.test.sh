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

# Lob exception: drop XCTest/Jest-style identifiers anywhere they appear
# (tests, docs, Vendor, skills). Keep real Lob test-mode keys (`test_<hex>`).
python3 - "$script_under_test" <<'PY'
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
assert "lob_test_api_key" in src, "Lob hex-key keep filter missing"
assert "test_identifier" in src, "Lob test-identifier drop filter missing"

# Keep these heuristics identical to scripts/security/scan-publishable-tree.sh.
lob_test_api_key = re.compile(r"^test_[0-9a-f]+$", re.IGNORECASE)
test_identifier = re.compile(r"^test_[A-Za-z_][A-Za-z0-9_]*$")
cases = [
    ("test_closedToOpen_afterThresholdFailures", True),
    ("test_everyMacEventIsRegisteredInTaxonomy", True),
    ("test_browserLaunchRejectsProfileMismatch", True),
    ("test_abc123deadbeef", False),  # hex-only Lob test-mode key shape
    ("live_prod_key_should_not_match", False),
]
for raw, expect_drop in cases:
    drop = bool(test_identifier.fullmatch(raw) and not lob_test_api_key.fullmatch(raw))
    assert drop is expect_drop, (raw, drop, expect_drop)
print("PASS: Lob false-positive exception covers camelCase test ids")
PY

echo "PASS: option-like publishable paths reach both scanner trees"
