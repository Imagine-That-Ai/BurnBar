# P-40 UTM Evidence Runbook

This runbook is the operator path for a real, candidate-bound P-40 privacy
session on the Ubuntu 24.04 aarch64 UTM VM. It does not use fixtures,
development binaries, branch daemons, or hand-authored claims. The final
`p40-live-session.json` must be produced by the signed installed candidate and
must contain only redacted metadata.

## Current status and stop conditions

The Linux Release Candidate run must be complete and successful before any
package is installed:

```text
run:        29351903622
target:     32b1e6aa4625a31454fbc0dacde404ce50f5a1f0
environment: ubuntu-24.04-gnome-x11-aarch64
```

Stop if any of these are false:

- the run is not `completed` with `conclusion=success`;
- its `headSha` is not `TARGET_HEAD`;
- the immutable artifact is not exactly `linux-release-evidence` from that
  run, or its resolver does not return a SHA-256 digest;
- the VM is not GNOME/X11 Ubuntu 24.04 aarch64;
- the installed manifest does not bind the package to `TARGET_HEAD`;
- the daemon is not the package-owned `/usr/bin/openburnbar-daemon` reached
  through `/usr/libexec/openburnbar-daemon-launch`.

Do not substitute a historical receipt or a branch-daemon transcript for this
candidate. Those are diagnostic evidence only.

## 1. Resolve and download the immutable candidate (host)

Run from a clean checkout at `TARGET_HEAD`. Keep all temporary files below the
named work directory; do not use the repository's dirty primary checkout.

```bash
set -euo pipefail

TARGET_HEAD=32b1e6aa4625a31454fbc0dacde404ce50f5a1f0
RUN_ID=29351903622
REPO=Imagine-That-Ai/BurnBar
ENVIRONMENT_ID=ubuntu-24.04-gnome-x11-aarch64
WORK_ROOT="/private/tmp/burnbar-p40-${RUN_ID}"
INPUT_ROOT="$WORK_ROOT/input/P-40/$ENVIRONMENT_ID"

df -h /System/Volumes/Data
git -C /private/tmp/burnbar-linux-parity-continuation status --short
mkdir -m 700 -p "$INPUT_ROOT"

gh run view "$RUN_ID" --repo "$REPO" \
  --json status,conclusion,headSha,url

OUTPUT_FILE="$WORK_ROOT/github-output"
```

The resolver writes `run_id`, `artifact_id`, and `artifact_digest` to
`GITHUB_OUTPUT`, so set it explicitly rather than relying on a shell's
existing CI variable:

```bash
export GITHUB_OUTPUT="$OUTPUT_FILE"
node scripts/linux-port/resolve-product-evidence-run.mjs \
  --run-id "$RUN_ID" \
  --target-head "$TARGET_HEAD"
unset GITHUB_OUTPUT

source "$OUTPUT_FILE"
test "$run_id" = "$RUN_ID"
test -n "$artifact_id"
[[ "$artifact_digest" =~ ^sha256:[0-9a-f]{64}$ ]]
```

Download by the immutable artifact id. This is equivalent to the
`actions/download-artifact` step used by the parity workflow and avoids
accidentally selecting another successful run:

```bash
gh api \
  -H 'Accept: application/vnd.github+json' \
  "/repos/$REPO/actions/artifacts/$artifact_id/zip" \
  > "$WORK_ROOT/linux-release-evidence.zip"
unzip -q "$WORK_ROOT/linux-release-evidence.zip" -d "$INPUT_ROOT"

find "$INPUT_ROOT" -type f -name '*.deb' -print
```

There must be exactly one aarch64 Debian package. Confirm its package metadata
before copying it to the VM:

```bash
DEB="$(find "$INPUT_ROOT" -type f -name '*.deb' -print -quit)"
test -n "$DEB"
test "$(dpkg-deb -f "$DEB" Architecture)" = arm64
test "$(dpkg-deb -f "$DEB" Package)" = open-burn-bar
PACKAGE_VERSION="$(dpkg-deb -f "$DEB" Version)"
printf 'candidate=%s version=%s\n' "$artifact_digest" "$PACKAGE_VERSION"
```

## 2. Install the exact package in UTM

The VM is documented in [`UTM_VM_ACCESS.md`](UTM_VM_ACCESS.md):

```bash
VM_HOST=192.168.64.5
VM_USER=burnbar
VM_KEY="$HOME/.ssh/openburnbar_linux_vm"
VM_ROOT="/home/burnbar/.cache/openburnbar-p40-${RUN_ID}"

ssh -i "$VM_KEY" "$VM_USER@$VM_HOST" \
  "umask 077; mkdir -p '$VM_ROOT/package' '$VM_ROOT/input' '$VM_ROOT/runtime'"
scp -i "$VM_KEY" "$DEB" \
  "$VM_USER@$VM_HOST:$VM_ROOT/package/open-burn-bar.deb"

ssh -i "$VM_KEY" "$VM_USER@$VM_HOST" \
  "TARGET_HEAD=$TARGET_HEAD RUN_ID=$RUN_ID bash -s" <<'REMOTE'
set -euo pipefail
DEB="$HOME/.cache/openburnbar-p40-${RUN_ID}/package/open-burn-bar.deb"
test "$(dpkg-deb -f "$DEB" Architecture)" = arm64
test "$(dpkg-deb -f "$DEB" Package)" = open-burn-bar
sudo apt-get install -y --reinstall "$DEB"
test -x /usr/libexec/openburnbar-daemon-launch
test -x /usr/bin/openburnbar-daemon
test -f /usr/share/openburnbar/attestation/installed-manifest.json
test -f /usr/share/openburnbar/attestation/installed-manifest.json.sig
TARGET_HEAD="$TARGET_HEAD" node <<'NODE'
const fs = require('node:fs');
const crypto = require('node:crypto');
const manifestPath = '/usr/share/openburnbar/attestation/installed-manifest.json';
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
if (manifest.gitCommit !== process.env.TARGET_HEAD) throw new Error('manifest gitCommit mismatch');
if (manifest.packageArchitecture !== 'aarch64' || manifest.packageFormat !== 'deb') {
  throw new Error('manifest package identity mismatch');
}
const manifestSha256 = crypto.createHash('sha256').update(fs.readFileSync(manifestPath)).digest('hex');
console.log(JSON.stringify({ manifestSha256, packageVersion: manifest.packageVersion }));
NODE
REMOTE

MANIFEST_SHA256="$(ssh -i "$VM_KEY" "$VM_USER@$VM_HOST" \
  'sha256sum /usr/share/openburnbar/attestation/installed-manifest.json | awk "{print \\$1}"')"
[[ "$MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]]
```

The manifest hash printed by the VM is the only value allowed in the P-40
`package.manifestSha256` field. Do not copy the manifest contents into the
session report.

## 3. Start an isolated installed daemon

Use a private support/runtime directory so the exercise cannot delete or
rewrite a user's existing data. The daemon is still the installed candidate;
only its XDG locations are isolated:

```bash
ssh -i "$VM_KEY" "$VM_USER@$VM_HOST" \
  "RUN_ID=$RUN_ID bash -s" <<'REMOTE'
set -euo pipefail
ROOT="$HOME/.cache/openburnbar-p40-${RUN_ID}"
SUPPORT="$ROOT/support"
RUNTIME="$ROOT/runtime"
SOCKET="$RUNTIME/openburnbar/daemon.sock"
mkdir -m 700 -p "$SUPPORT" "$RUNTIME/openburnbar" "$ROOT/evidence"
rm -f "$SOCKET" "$ROOT/daemon.log" "$ROOT/daemon.pid"
OPENBURNBAR_DAEMON_SUPPORT_DIR="$SUPPORT" \
OPENBURNBAR_DAEMON_SOCKET_PATH="$SOCKET" \
XDG_DATA_HOME="$ROOT/data" \
XDG_RUNTIME_DIR="$RUNTIME" \
/usr/libexec/openburnbar-daemon-launch >"$ROOT/daemon.log" 2>&1 &
echo $! >"$ROOT/daemon.pid"
for i in $(seq 1 60); do test -S "$SOCKET" && break; sleep 0.5; done
test -S "$SOCKET"
TOKEN_FILE="$SUPPORT/daemon-socket-auth-token"
test -f "$TOKEN_FILE"
test "$(stat -c %a "$TOKEN_FILE")" = 600
REMOTE
```

All RPCs are newline-framed JSON over the authenticated AF_UNIX socket. The
request envelope is `{id, method, authToken}` plus `params` for methods that
take a request object. The token must be read only by the producer and must
never be written to an evidence file.

## 4. Produce the live report (required producer)

The report producer must run these methods against the socket above and write
only redacted evidence files under `ROOT/evidence`:

```text
daemon.privacy.inventory
daemon.privacy.deletion.preview
daemon.privacy.deletion.execute
daemon.privacy.export
daemon.privacy.retention.status
daemon.privacy.retention.apply
```

The producer must use an isolated support directory and prove, with real RPC
responses and filesystem checks:

- metadata-only inventory for both allowlisted stores;
- preview scope binding, exact confirmation, changed/expired preview
  rejection, and idempotent execution;
- encrypted export format version 1, owner-only output, and no plaintext;
- default retention rules, bounded custom rules, invalid confirmation/bounds,
  old-route purge, fresh-route retention, aged expansion purge, and malformed
  store fail-closed with no mutation.

The resulting object must match the exact schema enforced by
`scripts/linux-port/lib/p40-privacy-proof.mjs` and must set
`capture.mode` to `installed-rpc`, `daemon.source` to
`installed-candidate-daemon`, and `package.source` to
`signed-installed-candidate`. Evidence paths must be relative, non-empty,
regular files and may not contain `fixture`, `mock`, `synthetic`, or `xvfb`.
Never include a token, passphrase, path, raw contents, or RPC response that
contains one.

The checked-in producer is
`scripts/linux-port/run-p40-privacy-rpc-session.mjs`. It has no test/fixture
mode and refuses to run against an existing store or a mismatched installed
manifest. The product-parity workflow invokes this producer after installing
the exact downloaded Debian candidate; do not substitute
`scripts/linux-port/p40-privacy-proof.test.mjs` or any fixture into the input
root. The workflow wiring is intentionally guarded to
`ubuntu-24.04-gnome-x11-aarch64`, which is the available UTM proof surface;
the other six P-40 matrix environments remain unclosed until equivalent
installed producers exist for their package/session combinations.

For a manual UTM run, copy the exact-target helper to the VM and invoke it
there. The helper must be source-audited before use; it must not be copied from
another branch:

```bash
scp -i "$VM_KEY" scripts/linux-port/run-p40-privacy-rpc-session.mjs \
  "$VM_USER@$VM_HOST:$VM_ROOT/run-p40-privacy-rpc-session.mjs"
ssh -i "$VM_KEY" "$VM_USER@$VM_HOST" \
  "RUN_ID=$RUN_ID ENVIRONMENT_ID=$ENVIRONMENT_ID TARGET_HEAD=$TARGET_HEAD CANDIDATE_ARTIFACT_DIGEST=$artifact_digest PACKAGE_VERSION=$PACKAGE_VERSION MANIFEST_SHA256=$MANIFEST_SHA256 bash -s" <<'REMOTE'
set -euo pipefail
ROOT="$HOME/.cache/openburnbar-p40-${RUN_ID}"
node "$ROOT/run-p40-privacy-rpc-session.mjs" \
  --socket "$ROOT/runtime/openburnbar/daemon.sock" \
  --token-file "$ROOT/support/daemon-socket-auth-token" \
  --output-root "$ROOT/evidence" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST" \
  --package-version "$PACKAGE_VERSION" \
  --manifest-sha256 "$MANIFEST_SHA256"
REMOTE
```

The producer's output is the only acceptable source for
`p40-live-session.json`.

## 5. Run the candidate-bound capture

Pull the report and its four non-empty evidence files into the clean checkout
that is exactly `TARGET_HEAD`, then run the existing fail-closed capture:

```bash
rsync -az -e "ssh -i $VM_KEY -o StrictHostKeyChecking=no" \
  "$VM_USER@$VM_HOST:$VM_ROOT/evidence/" "$INPUT_ROOT/"

test -f "$INPUT_ROOT/p40-live-session.json"
node scripts/linux-port/capture-p40-privacy-proof.mjs \
  --input-root "$INPUT_ROOT" \
  --session-report "$INPUT_ROOT/p40-live-session.json" \
  --environment "$ENVIRONMENT_ID" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$RUN_ID" \
  --candidate-artifact-digest "$artifact_digest"
```

The command emits `feature-artifacts/data-and-privacy-proof.json` and
`feature-proof-registration.json` under `INPUT_ROOT`. It also re-hashes all
privacy source contracts on the exact checkout, so a dirty or different
checkout fails closed.

## 6. Cleanup without losing evidence

After the report has been pulled and hashed, stop the isolated daemon and
remove the token/logs. Keep only the redacted report and evidence files until
the feature-proof closure is materialized:

```bash
ssh -i "$VM_KEY" "$VM_USER@$VM_HOST" \
  "RUN_ID=$RUN_ID bash -s" <<'REMOTE'
set -euo pipefail
ROOT="$HOME/.cache/openburnbar-p40-${RUN_ID}"
if test -f "$ROOT/daemon.pid"; then kill "$(cat "$ROOT/daemon.pid")" 2>/dev/null || true; fi
rm -f "$ROOT/support/daemon-socket-auth-token" "$ROOT/daemon.log" "$ROOT/daemon.pid" "$ROOT/run-p40-privacy-rpc-session.mjs"
REMOTE
rm -f "$WORK_ROOT/linux-release-evidence.zip" "$OUTPUT_FILE"
df -h /System/Volumes/Data
```

Do not delete the evidence root before the product-proof closure and
attestation steps have consumed it. The root is disposable after those
artifacts are signed and uploaded.
