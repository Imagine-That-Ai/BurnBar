#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=scripts/lib/pinned-xcodegen.sh
source "$repo_root/scripts/lib/pinned-xcodegen.sh"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-pinned-xcodegen.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

write_fake_xcodegen() {
  local path="$1"
  local version="$2"

  cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "--version" ]]; then
  printf 'Version: %s\\n' "$version"
  exit 0
fi
if [[ "\${1:-}" == "generate" && -n "\${OPENBURNBAR_FAKE_PROJECT_ROOT:-}" ]]; then
  printf 'generated\\n' >> "\${OPENBURNBAR_FAKE_PROJECT_ROOT}/AgentLens/Resources/OpenBurnBar-Info.plist"
  if [[ "\${OPENBURNBAR_FAKE_XCODEGEN_FAIL:-0}" == "1" ]]; then
    exit 17
  fi
  mkdir -p "\${OPENBURNBAR_FAKE_PROJECT_ROOT}/OpenBurnBar.xcodeproj"
  printf '%s\\n' "\${OPENBURNBAR_FAKE_PBX_CONTENT:-stable}" > "\${OPENBURNBAR_FAKE_PROJECT_ROOT}/OpenBurnBar.xcodeproj/project.pbxproj"
fi
printf '%s\\n' "\$*" >> "\${OPENBURNBAR_FAKE_XCODEGEN_LOG:?}"
EOF
  chmod +x "$path"
}

exact_bin="$fixture_root/xcodegen-exact"
wrong_bin="$fixture_root/xcodegen-wrong"
write_fake_xcodegen "$exact_bin" "$OPENBURNBAR_XCODEGEN_VERSION"
write_fake_xcodegen "$wrong_bin" "2.46.0"

valid_archive="$fixture_root/xcodegen.zip"
printf "verified fixture archive\n" > "$valid_archive"
fixture_archive_sha256="$(shasum --algorithm 256 "$valid_archive" | awk '{print $1}')"
openburnbar_verify_pinned_xcodegen_archive "$valid_archive" "$fixture_archive_sha256"
printf "tampered\n" >> "$valid_archive"
if openburnbar_verify_pinned_xcodegen_archive \
  "$valid_archive" \
  "$fixture_archive_sha256" \
  >"$fixture_root/archive.stdout" \
  2>"$fixture_root/archive.stderr"; then
  echo "ERROR: A tampered XcodeGen archive was accepted." >&2
  exit 1
fi
grep -F "archive checksum mismatch" "$fixture_root/archive.stderr" >/dev/null

resolved="$(
  OPENBURNBAR_XCODEGEN_BIN="$exact_bin" \
    openburnbar_resolve_pinned_xcodegen
)"
[[ "$resolved" == "$exact_bin" ]]

if OPENBURNBAR_XCODEGEN_BIN="$wrong_bin" \
  openburnbar_resolve_pinned_xcodegen >"$fixture_root/wrong.stdout" 2>"$fixture_root/wrong.stderr"; then
  echo "ERROR: A mismatched XcodeGen version was accepted." >&2
  exit 1
fi
grep -F "XcodeGen ${OPENBURNBAR_XCODEGEN_VERSION} is required" "$fixture_root/wrong.stderr" >/dev/null
grep -F "2.46.0" "$fixture_root/wrong.stderr" >/dev/null

if OPENBURNBAR_XCODEGEN_BIN="$fixture_root/missing" \
  openburnbar_resolve_pinned_xcodegen >"$fixture_root/missing.stdout" 2>"$fixture_root/missing.stderr"; then
  echo "ERROR: A missing XcodeGen executable was accepted." >&2
  exit 1
fi
grep -F "Set OPENBURNBAR_XCODEGEN_BIN" "$fixture_root/missing.stderr" >/dev/null

fake_log="$fixture_root/invocations.log"
OPENBURNBAR_XCODEGEN_BIN="$exact_bin" \
OPENBURNBAR_FAKE_XCODEGEN_LOG="$fake_log" \
  openburnbar_generate_xcode_project "$fixture_root/custom-project.yml"
grep -Fx "generate --spec $fixture_root/custom-project.yml" "$fake_log" >/dev/null

path_bin_dir="$fixture_root/path-bin"
mkdir -p "$path_bin_dir"
cp "$wrong_bin" "$path_bin_dir/xcodegen"
resolved="$(
  PATH="$path_bin_dir:$PATH" \
  OPENBURNBAR_XCODEGEN_BIN="$exact_bin" \
    openburnbar_resolve_pinned_xcodegen
)"
[[ "$resolved" == "$exact_bin" ]]

project_fixture="$fixture_root/project"
mkdir -p \
  "$project_fixture/OpenBurnBar.xcodeproj" \
  "$project_fixture/AgentLens/Resources" \
  "$project_fixture/OpenBurnBarSafariExtension" \
  "$project_fixture/OpenBurnBarMobile" \
  "$project_fixture/OpenBurnBarWidget" \
  "$project_fixture/OpenBurnBarKeyboard"
printf "name: Fixture\n" > "$project_fixture/project.yml"
printf "stable\n" > "$project_fixture/OpenBurnBar.xcodeproj/project.pbxproj"
for plist_path in \
  AgentLens/Resources/OpenBurnBar-Info.plist \
  OpenBurnBarSafariExtension/Info.plist \
  OpenBurnBarMobile/Info.plist \
  OpenBurnBarWidget/Info.plist \
  OpenBurnBarKeyboard/Info.plist; do
  printf "original %s\n" "$plist_path" > "$project_fixture/$plist_path"
done
fake_verifier="$fixture_root/verify-drift.py"
cat > "$fake_verifier" <<'PY'
#!/usr/bin/env python3
import pathlib
import sys

left = pathlib.Path(sys.argv[1]).read_bytes()
right = pathlib.Path(sys.argv[2]).read_bytes()
raise SystemExit(0 if left == right else 1)
PY
chmod +x "$fake_verifier"

mv "$project_fixture/OpenBurnBarKeyboard/Info.plist" \
  "$project_fixture/OpenBurnBarKeyboard/Info.plist.missing"
if OPENBURNBAR_XCODEGEN_BIN="$exact_bin" \
  OPENBURNBAR_FAKE_PROJECT_ROOT="$project_fixture" \
  OPENBURNBAR_FAKE_XCODEGEN_LOG="$fake_log" \
  OPENBURNBAR_XCODEGEN_DRIFT_VERIFIER="$fake_verifier" \
  openburnbar_verify_xcode_project_sync "$project_fixture"; then
  echo "ERROR: A missing generated Info.plist was accepted." >&2
  exit 1
fi
grep -Fx "stable" "$project_fixture/OpenBurnBar.xcodeproj/project.pbxproj" >/dev/null
mv "$project_fixture/OpenBurnBarKeyboard/Info.plist.missing" \
  "$project_fixture/OpenBurnBarKeyboard/Info.plist"

OPENBURNBAR_XCODEGEN_BIN="$exact_bin" \
OPENBURNBAR_FAKE_PROJECT_ROOT="$project_fixture" \
OPENBURNBAR_FAKE_XCODEGEN_LOG="$fake_log" \
OPENBURNBAR_XCODEGEN_DRIFT_VERIFIER="$fake_verifier" \
  openburnbar_verify_xcode_project_sync "$project_fixture"
grep -Fx "stable" "$project_fixture/OpenBurnBar.xcodeproj/project.pbxproj" >/dev/null
grep -Fx "original AgentLens/Resources/OpenBurnBar-Info.plist" \
  "$project_fixture/AgentLens/Resources/OpenBurnBar-Info.plist" >/dev/null

if OPENBURNBAR_XCODEGEN_BIN="$exact_bin" \
  OPENBURNBAR_FAKE_PROJECT_ROOT="$project_fixture" \
  OPENBURNBAR_FAKE_PBX_CONTENT="drifted" \
  OPENBURNBAR_FAKE_XCODEGEN_LOG="$fake_log" \
  OPENBURNBAR_XCODEGEN_DRIFT_VERIFIER="$fake_verifier" \
  openburnbar_verify_xcode_project_sync "$project_fixture"; then
  echo "ERROR: Semantic Xcode project drift was accepted." >&2
  exit 1
fi
grep -Fx "stable" "$project_fixture/OpenBurnBar.xcodeproj/project.pbxproj" >/dev/null
grep -Fx "original AgentLens/Resources/OpenBurnBar-Info.plist" \
  "$project_fixture/AgentLens/Resources/OpenBurnBar-Info.plist" >/dev/null

if OPENBURNBAR_XCODEGEN_BIN="$exact_bin" \
  OPENBURNBAR_FAKE_PROJECT_ROOT="$project_fixture" \
  OPENBURNBAR_FAKE_XCODEGEN_FAIL="1" \
  OPENBURNBAR_FAKE_XCODEGEN_LOG="$fake_log" \
  OPENBURNBAR_XCODEGEN_DRIFT_VERIFIER="$fake_verifier" \
  openburnbar_verify_xcode_project_sync "$project_fixture"; then
  echo "ERROR: A failed XcodeGen invocation was accepted." >&2
  exit 1
fi
grep -Fx "stable" "$project_fixture/OpenBurnBar.xcodeproj/project.pbxproj" >/dev/null
grep -Fx "original AgentLens/Resources/OpenBurnBar-Info.plist" \
  "$project_fixture/AgentLens/Resources/OpenBurnBar-Info.plist" >/dev/null

echo "Pinned XcodeGen helper tests passed."
