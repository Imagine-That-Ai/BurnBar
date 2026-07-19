#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: $0 <android-test.apk> <candidate-commit> <observed-identity.json>" >&2
  exit 64
fi

apk_path="$1"
candidate_commit="$2"
output_path="$3"
adb_bin="${ADB:-adb}"

if [[ ! -f "$apk_path" || -L "$apk_path" || ! -s "$apk_path" ]]; then
  echo "Android instrumentation APK must be a nonempty regular file: $apk_path" >&2
  exit 1
fi
if [[ ! "$candidate_commit" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Android candidate commit must be a full lowercase Git SHA-1" >&2
  exit 1
fi
if ! command -v "$adb_bin" >/dev/null 2>&1; then
  echo "adb executable is unavailable: $adb_bin" >&2
  exit 1
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/domain-core-android-load.XXXXXX")"
instrumentation_package=""
cleanup() {
  if [[ -n "$instrumentation_package" ]]; then
    "$adb_bin" uninstall "$instrumentation_package" >/dev/null 2>&1 || true
  fi
  rm -rf "$temporary_directory"
}
trap cleanup EXIT

fail_with_logs() {
  local message="$1"
  shift
  echo "$message" >&2
  for log_path in "$@"; do
    if [[ -s "$log_path" ]]; then
      echo "--- $(basename "$log_path") ---" >&2
      sed -n '1,200p' "$log_path" >&2
    fi
  done
  exit 1
}

install_stdout="$temporary_directory/install.stdout"
install_stderr="$temporary_directory/install.stderr"
if ! "$adb_bin" install -r -t "$apk_path" >"$install_stdout" 2>"$install_stderr"; then
  fail_with_logs \
    "Unable to install the domain-core Android instrumentation APK" \
    "$install_stdout" "$install_stderr"
fi

instrumentation_stdout="$temporary_directory/instrumentation-list.stdout"
instrumentation_stderr="$temporary_directory/instrumentation-list.stderr"
if ! "$adb_bin" shell pm list instrumentation >"$instrumentation_stdout" 2>"$instrumentation_stderr"; then
  fail_with_logs \
    "Unable to list installed Android instrumentation components" \
    "$instrumentation_stdout" "$instrumentation_stderr"
fi

instrumentation_components=()
while IFS= read -r instrumentation_component; do
  instrumentation_components+=("$instrumentation_component")
done < <(
  sed -nE \
    's/^instrumentation:([^[:space:]]+) \(target=([^)]*)\)\r?$/\1|\2/p' \
    "$instrumentation_stdout" \
    | awk -F'|' 'index($1, $2 "/") == 1 { print $1 }'
)
if [[ "${#instrumentation_components[@]}" -ne 1 ]]; then
  fail_with_logs \
    "Expected exactly one installed self-targeting domain-core instrumentation component; found ${#instrumentation_components[@]}" \
    "$instrumentation_stdout" "$instrumentation_stderr"
fi

instrumentation_component="${instrumentation_components[0]}"
instrumentation_package="${instrumentation_component%%/*}"
if [[ ! "$instrumentation_package" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$ ]]; then
  fail_with_logs \
    "Resolved Android instrumentation package is invalid: $instrumentation_package" \
    "$instrumentation_stdout"
fi

run_stdout="$temporary_directory/instrumentation-run.stdout"
run_stderr="$temporary_directory/instrumentation-run.stderr"
if ! "$adb_bin" shell am instrument -w -r \
  -e candidateCommit "$candidate_commit" \
  "$instrumentation_component" >"$run_stdout" 2>"$run_stderr"; then
  fail_with_logs \
    "Domain-core Android instrumentation command failed" \
    "$run_stdout" "$run_stderr"
fi
if ! grep -Eq '^OK \([1-9][0-9]* tests?\)\r?$' "$run_stdout" \
  || grep -Eq 'FAILURES!!!|INSTRUMENTATION_(FAILED|ABORTED)|Process crashed' "$run_stdout"; then
  fail_with_logs \
    "Domain-core Android instrumentation did not report a successful test run" \
    "$run_stdout" "$run_stderr"
fi

path_stdout="$temporary_directory/data-path.stdout"
path_stderr="$temporary_directory/data-path.stderr"
if ! "$adb_bin" shell run-as "$instrumentation_package" pwd >"$path_stdout" 2>"$path_stderr"; then
  fail_with_logs \
    "Unable to resolve the installed instrumentation data directory" \
    "$path_stdout" "$path_stderr"
fi
data_path="$(tr -d '\r\n' < "$path_stdout")"
escaped_package="${instrumentation_package//./\\.}"
if [[ ! "$data_path" =~ ^/data/(data|user/[0-9]+)/${escaped_package}$ ]]; then
  fail_with_logs \
    "Resolved instrumentation data directory is invalid: $data_path" \
    "$path_stdout" "$path_stderr"
fi

identity_stdout="$temporary_directory/observed-identity.json"
identity_stderr="$temporary_directory/observed-identity.stderr"
identity_path="$data_path/files/domain-core-observed-identity.json"
if ! "$adb_bin" exec-out run-as "$instrumentation_package" \
  cat "$identity_path" >"$identity_stdout" 2>"$identity_stderr"; then
  fail_with_logs \
    "Unable to read the observed Android Rust identity at $identity_path" \
    "$identity_stdout" "$identity_stderr"
fi

if ! node - "$identity_stdout" "$candidate_commit" <<'NODE'
const { readFileSync } = require("node:fs");

const [path, candidateCommit] = process.argv.slice(2);
let identity;
try {
  identity = JSON.parse(readFileSync(path, "utf8"));
} catch (error) {
  throw new Error(`observed Android Rust identity is invalid JSON: ${error.message}`);
}
if (!identity || typeof identity !== "object" || Array.isArray(identity)) {
  throw new Error("observed Android Rust identity must be an object");
}
const expectedKeys = [
  "abiVersion",
  "binarySha256",
  "candidateCommit",
  "coreVersion",
  "sourceSha256",
];
const keys = Object.keys(identity).sort();
if (JSON.stringify(keys) !== JSON.stringify(expectedKeys)) {
  throw new Error(`observed Android Rust identity has unexpected keys: ${keys.join(",")}`);
}
if (identity.candidateCommit !== candidateCommit) {
  throw new Error("observed Android Rust identity candidate commit mismatch");
}
if (!/^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.test(identity.coreVersion)) {
  throw new Error("observed Android Rust identity core version is invalid");
}
if (!Number.isSafeInteger(identity.abiVersion) || identity.abiVersion < 1 || identity.abiVersion > 0xffffffff) {
  throw new Error("observed Android Rust identity ABI version is invalid");
}
for (const field of ["sourceSha256", "binarySha256"]) {
  if (typeof identity[field] !== "string" || !/^[0-9a-f]{64}$/.test(identity[field])) {
    throw new Error(`observed Android Rust identity ${field} is invalid`);
  }
}
NODE
then
  fail_with_logs \
    "Observed Android Rust identity failed canonical validation" \
    "$identity_stdout" "$identity_stderr"
fi

mkdir -p "$(dirname "$output_path")"
mv "$identity_stdout" "$output_path"
echo "Verified loaded Android Rust identity from $instrumentation_component" >&2
