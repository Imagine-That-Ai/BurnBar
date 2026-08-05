#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
umask 077

ENVIRONMENT_ID="${ENVIRONMENT_ID:-}"
RUNNER_TEMP="${RUNNER_TEMP:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd "$script_dir/../.." && pwd -P)"

environment_id=""
expected_architecture=""
expected_format=""
expected_os_id=""
expected_os_version=""
expected_desktop=""
expected_session=""
expected_package_name=""
candidate_package=""
candidate_version=""
runner_temp=""
temporary_root=""
candidate_root=""
daemon_pid=""
socket_path=""
token_file=""
evidence_root=""
declare -a pending_atomic_files=("")

die() {
  printf 'P-40 installed privacy proof failed: %s\n' "$*" >&2
  return 1
}

require_environment_variable() {
  local name="$1"
  test -n "${!name:-}" || die "required environment variable is missing: $name"
}

assert_no_symlink_components() {
  local target="$1"
  local label="$2"
  local current="/"
  local component
  local -a components=()

  [[ "$target" = /* ]] || die "$label must be absolute"
  IFS='/' read -r -a components <<<"${target#/}"
  for component in "${components[@]}"; do
    test -n "$component" || continue
    current="${current%/}/$component"
    if test -L "$current"; then
      die "$label traverses a symlink: $current"
    fi
    if ! test -e "$current"; then
      break
    fi
  done
}

assert_trusted_directory() {
  local directory="$1"
  local label="$2"
  local owner mode

  assert_no_symlink_components "$directory" "$label"
  test -d "$directory" || die "$label is not a directory"
  owner="$(stat -c '%u' "$directory")"
  mode="$(stat -c '%a' "$directory")"
  test "$owner" = "$(id -u)" || die "$label is not owned by the current user"
  (( (8#$mode & 0022) == 0 )) || die "$label is group/world-writable"
}

assert_regular_file_inside() {
  local root="$1"
  local file="$2"
  local label="$3"
  local resolved_root resolved_file

  [[ "$file" != *$'\n'* && "$file" != *$'\r'* && "$file" != *$'\t'* ]] \
    || die "$label contains control characters"
  assert_no_symlink_components "$file" "$label"
  if ! test -f "$file" || test -L "$file"; then
    die "$label is not a regular non-symlink file"
  fi
  resolved_root="$(realpath "$root")"
  resolved_file="$(realpath "$file")"
  case "$resolved_file" in
    "$resolved_root"/*) ;;
    *) die "$label escapes its trusted root" ;;
  esac
}

configure_environment() {
  environment_id="$1"
  case "$environment_id" in
    ubuntu-24.04-gnome-x11-x86_64)
      expected_architecture="x86_64"
      expected_format="deb"
      expected_os_id="ubuntu"
      expected_os_version="24.04"
      expected_desktop="GNOME"
      expected_session="X11"
      expected_package_name="open-burn-bar"
      ;;
    ubuntu-24.04-gnome-x11-aarch64)
      expected_architecture="aarch64"
      expected_format="deb"
      expected_os_id="ubuntu"
      expected_os_version="24.04"
      expected_desktop="GNOME"
      expected_session="X11"
      expected_package_name="open-burn-bar"
      ;;
    ubuntu-24.04-gnome-wayland-x86_64)
      expected_architecture="x86_64"
      expected_format="deb"
      expected_os_id="ubuntu"
      expected_os_version="24.04"
      expected_desktop="GNOME"
      expected_session="Wayland"
      expected_package_name="open-burn-bar"
      ;;
    ubuntu-24.04-gnome-wayland-aarch64)
      expected_architecture="aarch64"
      expected_format="deb"
      expected_os_id="ubuntu"
      expected_os_version="24.04"
      expected_desktop="GNOME"
      expected_session="Wayland"
      expected_package_name="open-burn-bar"
      ;;
    fedora-kde-wayland-x86_64)
      expected_architecture="x86_64"
      expected_format="rpm"
      expected_os_id="fedora"
      expected_os_version=""
      expected_desktop="KDE Plasma"
      expected_session="Wayland"
      expected_package_name="open-burn-bar"
      ;;
    fedora-kde-wayland-aarch64)
      expected_architecture="aarch64"
      expected_format="rpm"
      expected_os_id="fedora"
      expected_os_version=""
      expected_desktop="KDE Plasma"
      expected_session="Wayland"
      expected_package_name="open-burn-bar"
      ;;
    arch-sway-wayland-x86_64)
      expected_architecture="x86_64"
      expected_format="arch"
      expected_os_id="arch"
      expected_os_version=""
      expected_desktop="Sway/wlroots"
      expected_session="Wayland"
      expected_package_name="openburnbar"
      ;;
    *)
      die "unknown canonical P-40 environment: $environment_id"
      ;;
  esac
}

desktop_marker_matches() {
  local observed="${1^^}"
  case "$expected_desktop" in
    GNOME) [[ "$observed" == *GNOME* ]] ;;
    "KDE Plasma") [[ "$observed" == *KDE* || "$observed" == *PLASMA* ]] ;;
    "Sway/wlroots") [[ "$observed" == *SWAY* ]] ;;
    *) return 1 ;;
  esac
}

desktop_process_is_running() {
  local process_name
  case "$expected_desktop" in
    GNOME) process_name="gnome-shell" ;;
    "KDE Plasma") process_name="plasmashell" ;;
    "Sway/wlroots") process_name="sway" ;;
    *) return 1 ;;
  esac
  pgrep -u "$(id -u)" -x "$process_name" >/dev/null
}

verify_live_desktop_session() {
  local session_id session_uid details type desktop class active remote state

  command -v loginctl >/dev/null || die "cannot prove the live desktop session without loginctl"
  while IFS=$' \t' read -r session_id session_uid _; do
    test -n "${session_id:-}" && test "${session_uid:-}" = "$(id -u)" || continue
    details="$(loginctl show-session "$session_id" \
      -p Type -p Desktop -p Class -p Active -p Remote -p State --no-pager)" || continue
    type="$(awk -F= '$1 == "Type" { print $2 }' <<<"$details")"
    desktop="$(awk -F= '$1 == "Desktop" { print $2 }' <<<"$details")"
    class="$(awk -F= '$1 == "Class" { print $2 }' <<<"$details")"
    active="$(awk -F= '$1 == "Active" { print $2 }' <<<"$details")"
    remote="$(awk -F= '$1 == "Remote" { print $2 }' <<<"$details")"
    state="$(awk -F= '$1 == "State" { print $2 }' <<<"$details")"
    [[ "${type,,}" = "${expected_session,,}" ]] || continue
    test "$class" = "user" && test "$active" = "yes" && test "$remote" = "no" || continue
    [[ "${state,,}" = "active" || "${state,,}" = "online" ]] || continue
    if desktop_marker_matches "$desktop"; then
      return 0
    fi
    if test -z "$desktop" && desktop_process_is_running; then
      return 0
    fi
  done < <(loginctl list-sessions --no-legend --no-pager)
  die "no active local desktop session matches $environment_id"
}

verify_live_environment() {
  local os_id="" version_id="" key value architecture

  test "$(uname -s)" = "Linux" || die "P-40 installed proof must run on Linux"
  while IFS='=' read -r key value; do
    value="${value#\"}"
    value="${value%\"}"
    case "$key" in
      ID) os_id="$value" ;;
      VERSION_ID) version_id="$value" ;;
    esac
  done < /etc/os-release
  test "$os_id" = "$expected_os_id" || die "running OS id $os_id does not match $environment_id"
  if test -n "$expected_os_version"; then
    test "$version_id" = "$expected_os_version" \
      || die "running OS version $version_id does not match $environment_id"
  fi

  architecture="$(uname -m)"
  test "$architecture" = "$expected_architecture" \
    || die "running architecture $architecture does not match $environment_id"
  verify_live_desktop_session
}

inspect_candidate_package() {
  local package="$1"
  node --input-type=module - "$repo_root" "$expected_format" "$package" <<'NODE'
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [repoRoot, format, artifact] = process.argv.slice(2);
const moduleUrl = pathToFileURL(path.join(repoRoot, 'scripts/linux-port/lib/linux-native-package.mjs'));
const { inspectNativePackageMetadata } = await import(moduleUrl.href);
const metadata = inspectNativePackageMetadata(format, artifact);
for (const [key, value] of Object.entries(metadata)) {
  if (typeof value !== 'string' || value.length === 0 || /[\u0000-\u001f\u007f]/u.test(value)) {
    throw new Error(`unsafe candidate package metadata: ${key}`);
  }
}
process.stdout.write(
  `${metadata.packageName}\t${metadata.packageVersion}\t${metadata.packageArchitecture}\n`
);
NODE
}

select_candidate_package() {
  local input_root="$1"
  local pattern package metadata package_name package_version package_architecture
  local -a matches=()
  local -a versions=()

  case "$expected_format" in
    deb) pattern='*.deb' ;;
    rpm) pattern='*.rpm' ;;
    arch) pattern='*.pkg.tar.zst' ;;
    *) die "unsupported package format: $expected_format" ;;
  esac

  while IFS= read -r -d '' package; do
    assert_regular_file_inside "$input_root" "$package" "candidate package"
    metadata="$(inspect_candidate_package "$package")"
    IFS=$'\t' read -r package_name package_version package_architecture <<<"$metadata"
    if test "$package_name" = "$expected_package_name" \
      && test "$package_architecture" = "$expected_architecture"; then
      matches+=("$package")
      versions+=("$package_version")
    fi
  done < <(find "$input_root" -type f -name "$pattern" -print0)

  test "${#matches[@]}" -eq 1 \
    || die "expected exactly one $expected_format $expected_package_name package for $expected_architecture; found ${#matches[@]}"
  candidate_package="${matches[0]}"
  candidate_version="${versions[0]}"
}

install_candidate_package() {
  local installed_rpm_identity=""
  case "$expected_format" in
    deb)
      sudo apt-get install -y --reinstall "$candidate_package"
      ;;
    rpm)
      installed_rpm_identity="$(rpm -q --queryformat '%{VERSION}\t%{ARCH}\n' \
        "$expected_package_name" 2>/dev/null || true)"
      if test "$installed_rpm_identity" = "$candidate_version"$'\t'"$expected_architecture"; then
        sudo dnf reinstall -y "$candidate_package"
      else
        sudo dnf install -y "$candidate_package"
      fi
      ;;
    arch)
      sudo pacman -U --noconfirm "$candidate_package"
      ;;
    *)
      die "unsupported package format: $expected_format"
      ;;
  esac
}

verify_installed_candidate() {
  node --input-type=module - \
    "$repo_root" "$expected_format" "$expected_architecture" "$expected_package_name" \
    "$candidate_version" "$TARGET_HEAD" <<'NODE'
import crypto from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [repoRoot, expectedFormat, expectedArchitecture, expectedName, expectedVersion, targetHead] =
  process.argv.slice(2);
const liveModuleUrl = pathToFileURL(
  path.join(repoRoot, 'scripts/linux-port/lib/live-installed-product-evidence.mjs')
);
const { verifyLiveInstalledProduct } = await import(liveModuleUrl.href);
const manifestPath = '/usr/share/openburnbar/attestation/installed-manifest.json';
const signaturePath = `${manifestPath}.sig`;
const publicKeyPath = '/usr/share/openburnbar/attestation/release-ed25519.pub.pem';
const manifestBytes = fs.readFileSync(manifestPath);
const signatureBytes = fs.readFileSync(signaturePath);
const manifest = JSON.parse(manifestBytes.toString('utf8'));

if (manifest.gitCommit !== targetHead
    || manifest.packageFormat !== expectedFormat
    || manifest.packageArchitecture !== expectedArchitecture
    || manifest.packageName !== expectedName
    || manifest.packageVersion !== expectedVersion) {
  throw new Error('installed signed manifest identity does not match the selected candidate');
}
const verified = verifyLiveInstalledProduct({
  installedManifest: manifest,
  expectedManifestBytes: manifestBytes,
  expectedSignatureBytes: signatureBytes
});
const installedKey = verified.publicKeyBytes;
const repositoryKeyResult = spawnSync(
  'git',
  ['-C', repoRoot, 'show', `${targetHead}:packaging/linux/openburnbar-linux-ed25519.pub.pem`],
  { encoding: 'buffer', timeout: 15_000, maxBuffer: 64 * 1024 }
);
if (repositoryKeyResult.error || repositoryKeyResult.status !== 0) {
  throw new Error('unable to read the release trust anchor from TARGET_HEAD');
}
const repositoryKey = repositoryKeyResult.stdout;
if (installedKey.length !== repositoryKey.length
    || !crypto.timingSafeEqual(installedKey, repositoryKey)) {
  throw new Error('installed release key does not match the target checkout trust anchor');
}

function run(command, args) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: 'C' },
    timeout: 30_000,
    maxBuffer: 1024 * 1024
  });
  if (result.error || result.status !== 0) {
    throw new Error(`installed package query failed: ${command}`);
  }
  return result.stdout;
}

let managerName;
let managerVersion;
let managerArchitecture;
if (expectedFormat === 'deb') {
  [managerName, managerVersion, managerArchitecture] = run(
    'dpkg-query',
    ['-W', '-f=${Package}\t${Version}\t${Architecture}\n', expectedName]
  ).trim().split('\t');
  managerArchitecture = managerArchitecture === 'amd64' ? 'x86_64'
    : managerArchitecture === 'arm64' ? 'aarch64' : managerArchitecture;
} else if (expectedFormat === 'rpm') {
  [managerName, managerVersion, managerArchitecture] = run(
    'rpm',
    ['-q', '--queryformat', '%{NAME}\t%{VERSION}\t%{ARCH}\n', expectedName]
  ).trim().split('\t');
} else if (expectedFormat === 'arch') {
  const fields = new Map();
  for (const line of run('pacman', ['-Qi', expectedName]).split('\n')) {
    const match = /^([^:]+)\s*:\s*(.*)$/u.exec(line);
    if (match) fields.set(match[1].trim(), match[2].trim());
  }
  managerName = fields.get('Name');
  managerVersion = (fields.get('Version') ?? '').replace(/-[1-9][0-9]*$/u, '');
  managerArchitecture = fields.get('Architecture');
} else {
  throw new Error(`unsupported installed package format: ${expectedFormat}`);
}
if (managerName !== expectedName || managerVersion !== expectedVersion
    || managerArchitecture !== expectedArchitecture) {
  throw new Error('native package manager identity does not match the selected candidate');
}

const manifestSha256 = crypto.createHash('sha256').update(manifestBytes).digest('hex');
process.stdout.write(`${expectedVersion}\t${manifestSha256}\n`);
NODE
}

start_isolated_daemon() {
  local launcher="/usr/libexec/openburnbar-daemon-launch"
  local attempts=0 mode owner executable

  if ! test -x "$launcher" || test -L "$launcher"; then
    die "installed daemon launcher is not trusted"
  fi
  install -d -m 700 \
    "$candidate_root/home" \
    "$candidate_root/support" \
    "$candidate_root/data" \
    "$candidate_root/config" \
    "$candidate_root/cache" \
    "$candidate_root/state" \
    "$candidate_root/runtime/openburnbar" \
    "$candidate_root/evidence"
  socket_path="$candidate_root/runtime/openburnbar/daemon.sock"
  token_file="$candidate_root/support/daemon-socket-auth-token"
  evidence_root="$candidate_root/evidence"

  HOME="$candidate_root/home" \
  XDG_DATA_HOME="$candidate_root/data" \
  XDG_CONFIG_HOME="$candidate_root/config" \
  XDG_CACHE_HOME="$candidate_root/cache" \
  XDG_STATE_HOME="$candidate_root/state" \
  XDG_RUNTIME_DIR="$candidate_root/runtime" \
  OPENBURNBAR_DAEMON_SUPPORT_DIR="$candidate_root/support" \
  OPENBURNBAR_DAEMON_SOCKET_PATH="$socket_path" \
  "$launcher" >"$candidate_root/daemon.log" 2>&1 &
  daemon_pid=$!

  while (( attempts < 60 )); do
    test -S "$socket_path" && break
    kill -0 "$daemon_pid" 2>/dev/null || die "installed daemon exited before opening its isolated socket"
    sleep 0.5
    attempts=$((attempts + 1))
  done
  test -S "$socket_path" || die "installed daemon did not open its isolated socket"
  if ! test -f "$token_file" || test -L "$token_file"; then
    die "installed daemon token is not a regular file"
  fi
  mode="$(stat -c '%a' "$token_file")"
  owner="$(stat -c '%u' "$token_file")"
  test "$mode" = "600" && test "$owner" = "$(id -u)" \
    || die "installed daemon token is not owner-only"
  executable="$(readlink "/proc/$daemon_pid/exe")"
  test "$executable" = "/usr/bin/openburnbar-daemon" \
    || die "isolated process is not the package-owned daemon"
}

run_privacy_producer() {
  local package_version="$1"
  local manifest_sha256="$2"

  LD_LIBRARY_PATH="/usr/lib/openburnbar/swift:/usr/lib/openburnbar/native" \
  node "$script_dir/run-p40-privacy-rpc-session.mjs" \
    --socket "$socket_path" \
    --token-file "$token_file" \
    --output-root "$evidence_root" \
    --environment "$environment_id" \
    --target-head "$TARGET_HEAD" \
    --candidate-run-id "$CANDIDATE_RUN_ID" \
    --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
    --package-version "$package_version" \
    --manifest-sha256 "$manifest_sha256"
}

validate_evidence_tree() {
  local root="$1"
  node --input-type=module - \
    "$repo_root" "$root" "$environment_id" "$TARGET_HEAD" \
    "$CANDIDATE_RUN_ID" "$CANDIDATE_ARTIFACT_DIGEST" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [repoRoot, evidenceRoot, environmentId, targetHead, candidateRunId, candidateArtifactDigest] =
  process.argv.slice(2);
const proofModuleUrl = pathToFileURL(path.join(repoRoot, 'scripts/linux-port/lib/p40-privacy-proof.mjs'));
const { validateP40LiveSession } = await import(proofModuleUrl.href);
const expectedFiles = [
  'p40-live-session.json',
  'privacy/inventory.json',
  'privacy/deletion.json',
  'privacy/export.json',
  'privacy/retention.json'
];
const resolvedRoot = fs.realpathSync(evidenceRoot);

function readTrusted(relative, label) {
  if (path.posix.normalize(relative) !== relative || path.posix.isAbsolute(relative)
      || relative === '..' || relative.startsWith('../') || relative.includes('\\')) {
    throw new Error(`${label} is not a canonical relative path`);
  }
  let current = resolvedRoot;
  for (const component of relative.split('/')) {
    current = path.join(current, component);
    const stat = fs.lstatSync(current);
    if (stat.isSymbolicLink()) throw new Error(`${label} traverses a symlink`);
  }
  const stat = fs.lstatSync(current);
  if (!stat.isFile() || stat.size === 0 || stat.uid !== process.getuid()
      || (stat.mode & 0o077) !== 0) {
    throw new Error(`${label} must be a non-empty owner-only regular file`);
  }
  return fs.readFileSync(current);
}

const session = JSON.parse(readTrusted('p40-live-session.json', 'P-40 session').toString('utf8'));
validateP40LiveSession(session, {
  environmentId,
  targetHead,
  candidateRunId,
  candidateArtifactDigest
});
const referenced = [...new Set(
  Object.values(session.observations).flatMap((observation) => observation.evidencePaths ?? [])
)].sort();
const expectedReferenced = expectedFiles.slice(1).sort();
if (JSON.stringify(referenced) !== JSON.stringify(expectedReferenced)) {
  throw new Error('P-40 session does not reference exactly the canonical evidence files');
}
const expectedDocuments = new Map([
  ['privacy/inventory.json', {
    metadataOnly: session.observations.inventory.metadataOnly,
    stores: session.observations.inventory.stores
  }],
  ['privacy/deletion.json', { checks: session.observations.deletion }],
  ['privacy/export.json', { checks: session.observations.export }],
  ['privacy/retention.json', { checks: session.observations.retention }]
]);
function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
  }
  return value;
}
for (const [relative, expectedDocument] of expectedDocuments) {
  const actualDocument = JSON.parse(readTrusted(relative, `P-40 evidence ${relative}`).toString('utf8'));
  if (JSON.stringify(stable(actualDocument)) !== JSON.stringify(stable(expectedDocument))) {
    throw new Error(`P-40 evidence ${relative} does not match its validated session observation`);
  }
}
process.stdout.write('validated\n');
NODE
}

atomic_copy() {
  local source="$1"
  local destination="$2"
  local temporary owner mode

  if test -e "$destination" || test -L "$destination"; then
    assert_no_symlink_components "$destination" "existing P-40 evidence destination"
    if ! test -f "$destination" || test -L "$destination"; then
      die "existing P-40 evidence destination is not a regular file"
    fi
    owner="$(stat -c '%u' "$destination")"
    mode="$(stat -c '%a' "$destination")"
    test "$owner" = "$(id -u)" || die "existing P-40 evidence destination has the wrong owner"
    (( (8#$mode & 0022) == 0 )) || die "existing P-40 evidence destination is group/world-writable"
  fi

  temporary="$(mktemp "${destination}.p40-tmp.XXXXXX")"
  pending_atomic_files+=("$temporary")
  install -m 600 "$source" "$temporary"
  mv -f "$temporary" "$destination"
}

copy_validated_evidence() {
  local input_root="$1"
  local staging="$temporary_root/validated-evidence"
  local relative destination_parent
  local -a files=(
    "p40-live-session.json"
    "privacy/inventory.json"
    "privacy/deletion.json"
    "privacy/export.json"
    "privacy/retention.json"
  )

  validate_evidence_tree "$evidence_root"
  install -d -m 700 "$staging/privacy"
  for relative in "${files[@]}"; do
    install -m 600 "$evidence_root/$relative" "$staging/$relative"
  done
  validate_evidence_tree "$staging"

  if test -e "$input_root/privacy"; then
    assert_trusted_directory "$input_root/privacy" "P-40 destination privacy directory"
  else
    install -d -m 700 "$input_root/privacy"
  fi
  for relative in "${files[@]}"; do
    destination_parent="$(dirname "$input_root/$relative")"
    assert_trusted_directory "$destination_parent" "P-40 evidence destination"
    atomic_copy "$staging/$relative" "$input_root/$relative"
  done
}

cleanup() {
  local status=$?
  local attempts=0 temporary
  trap - EXIT
  set +e

  if test -n "$daemon_pid"; then
    kill "$daemon_pid" 2>/dev/null
    while kill -0 "$daemon_pid" 2>/dev/null && (( attempts < 20 )); do
      sleep 0.1
      attempts=$((attempts + 1))
    done
    if kill -0 "$daemon_pid" 2>/dev/null; then
      kill -KILL "$daemon_pid" 2>/dev/null
    fi
    wait "$daemon_pid" 2>/dev/null
  fi
  for temporary in "${pending_atomic_files[@]}"; do
    test -n "$temporary" && rm -f -- "$temporary"
  done
  if test -n "$temporary_root"; then
    case "$temporary_root" in
      "$runner_temp"/openburnbar-p40-runner.*)
        rm -rf -- "$temporary_root" || status=1
        ;;
      *)
        printf 'P-40 cleanup refused unexpected temporary path: %s\n' "$temporary_root" >&2
        status=1
        ;;
    esac
  fi
  exit "$status"
}

main() {
  local input_root installed_identity package_version manifest_sha256
  local command_name

  for command_name in awk find git id install loginctl mktemp node pgrep readlink realpath \
    stat sudo uname; do
    command -v "$command_name" >/dev/null || die "required command is unavailable: $command_name"
  done
  for variable in REQUIREMENT_ID ENVIRONMENT_ID CANDIDATE_RUN_ID \
    CANDIDATE_ARTIFACT_DIGEST TARGET_HEAD RUNNER_TEMP; do
    require_environment_variable "$variable"
  done
  test "$REQUIREMENT_ID" = "P-40" || die "runner is restricted to P-40"
  [[ "$TARGET_HEAD" =~ ^[a-f0-9]{40,64}$ ]] || die "TARGET_HEAD is invalid"
  [[ "$CANDIDATE_RUN_ID" =~ ^[1-9][0-9]*$ ]] || die "CANDIDATE_RUN_ID is invalid"
  [[ "$CANDIDATE_ARTIFACT_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] \
    || die "CANDIDATE_ARTIFACT_DIGEST is invalid"
  test "$(git -C "$repo_root" rev-parse --verify HEAD)" = "$TARGET_HEAD" \
    || die "checkout HEAD does not match TARGET_HEAD"
  git -C "$repo_root" diff --quiet HEAD -- \
    scripts/linux-port/run-p40-installed-privacy-proof.sh \
    scripts/linux-port/run-p40-privacy-rpc-session.mjs \
    scripts/linux-port/lib/p40-privacy-proof.mjs \
    scripts/linux-port/lib/product-proof-closure.mjs \
    scripts/linux-port/lib/live-installed-product-evidence.mjs \
    scripts/linux-port/lib/linux-installed-manifest.mjs \
    scripts/linux-port/lib/linux-native-package.mjs \
    packaging/linux/openburnbar-linux-ed25519.pub.pem \
    || die "P-40 runner trust files differ from TARGET_HEAD"

  configure_environment "$ENVIRONMENT_ID"
  [[ "$RUNNER_TEMP" = /* ]] || die "RUNNER_TEMP must be absolute"
  assert_no_symlink_components "$RUNNER_TEMP" "RUNNER_TEMP"
  runner_temp="$(realpath "$RUNNER_TEMP")"
  assert_trusted_directory "$runner_temp" "RUNNER_TEMP"
  input_root="$repo_root/docs/linux-port/evidence/product-parity-inputs/P-40/$environment_id"
  assert_trusted_directory "$input_root" "P-40 input root"
  verify_live_environment
  select_candidate_package "$input_root"

  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  temporary_root="$(mktemp -d "$runner_temp/openburnbar-p40-runner.XXXXXX")"
  chmod 700 "$temporary_root"
  candidate_root="$temporary_root/openburnbar-p40-$CANDIDATE_RUN_ID"
  install -d -m 700 "$candidate_root"

  install_candidate_package
  installed_identity="$(verify_installed_candidate)"
  IFS=$'\t' read -r package_version manifest_sha256 <<<"$installed_identity"
  test "$package_version" = "$candidate_version" \
    || die "installed package version changed after verification"
  [[ "$manifest_sha256" =~ ^[a-f0-9]{64}$ ]] || die "installed manifest hash is invalid"

  start_isolated_daemon
  run_privacy_producer "$package_version" "$manifest_sha256"
  copy_validated_evidence "$input_root"
  printf 'P-40 installed privacy proof evidence captured for %s\n' "$environment_id"
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
  main "$@"
fi
