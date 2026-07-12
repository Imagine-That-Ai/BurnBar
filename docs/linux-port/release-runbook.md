# Linux release runbook

The Linux release lane extends the macOS direct-download trust bar. Linux
artifacts must not be promoted from unsigned, untested, dirty, or synthetic
evidence.

As of 2026-07-05, V24 foundation and V23 surface validation passed at
`1b62ec42bd752cc8a6af578f034bf776c6ec3b97`. The checkout later moved to
`1af805eb1878cc5af8821ee35cac838c5ac473ee`, so that evidence is the last green
seal, not current-head release closure. Release promotion still requires a
rerun at the release head plus the package, update, signature/provenance,
nightly, and clean-commit evidence below.

## Artifacts

Required package artifacts:

- AppImage primary artifact.
- Debian package.
- RPM package.
- AUR metadata in [`../../packaging/linux/aur/PKGBUILD`](../../packaging/linux/aur/PKGBUILD).
- Flatpak tail metadata in
  [`../../packaging/linux/flatpak/dev.openburnbar.OpenBurnBar.yml`](../../packaging/linux/flatpak/dev.openburnbar.OpenBurnBar.yml).
- Desktop entry, autostart entry, and systemd user service under
  [`../../packaging/linux/`](../../packaging/linux/).
- Daemon launch script
  [`../../packaging/linux/openburnbar-daemon-launch.sh`](../../packaging/linux/openburnbar-daemon-launch.sh)
  installed to **`/usr/libexec/openburnbar-daemon-launch`** (required by the
  unit `ExecStart`; missing install causes systemd 203/EXEC).
- Architecture-matched daemon payload in every AppImage/deb/rpm:
  `/usr/bin/openburnbar-daemon`, the Swift runtime under
  `/usr/lib/openburnbar/swift`, and SQLCipher shared libraries under
  `/usr/lib/openburnbar/native`. `npm run tauri:build` stages and executes the
  daemon with those exact packaged libraries before Tauri bundles anything.
- Every deb/rpm owns a root-installed Ed25519 trust set under
  `/usr/share/openburnbar/attestation/`: the canonical installed-file manifest,
  its raw 64-byte signature, and the pinned release public key. The signed
  inventory covers every package-owned non-directory path except the manifest
  and signature themselves, including the desktop and daemon executables. The
  shard closure binds the exact manifest and signature bytes by path, SHA-256,
  and size.
- Custom XDG drop-in example:
  [`../../packaging/linux/systemd/openburnbar-daemon.service.d/custom-xdg.conf.example`](../../packaging/linux/systemd/openburnbar-daemon.service.d/custom-xdg.conf.example).

Build locally:

```bash
export OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID="...apps.googleusercontent.com"
export OPENBURNBAR_FIREBASE_API_KEY="..."
export OPENBURNBAR_LINUX_APP_CHECK_APP_ID="1:...:web:..."
export VERSION="1.2.3"
export COMMIT="$(git rev-parse HEAD)"
export ARCH="$(node -p "process.arch === 'arm64' ? 'aarch64' : 'x86_64'")"
export OUT="$PWD/.linux-shard"
export TOOLCHAIN="openburnbar-linux-toolchain:mission-001"
docker build -t "$TOOLCHAIN" tools/linux-toolchain
docker run --rm \
  -e OPENBURNBAR_LINUX_RELEASE_OUT=/workspace/.linux-shard \
  -e OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID \
  -e OPENBURNBAR_FIREBASE_API_KEY \
  -e OPENBURNBAR_LINUX_APP_CHECK_APP_ID \
  -v "$PWD:/workspace" -w /workspace "$TOOLCHAIN" \
  node scripts/linux-port/build-linux-release.mjs \
    --architecture-shard --phase prepare --version "$VERSION"

SIGNER_ROOT="$(mktemp -d)"
git archive "$COMMIT" \
  scripts/linux-port/sign-linux-release-requests.mjs \
  scripts/linux-port/lib/linux-installed-manifest.mjs \
  scripts/linux-port/lib/linux-appimage-peer-manifest.mjs \
  packaging/linux/openburnbar-linux-ed25519.pub.pem \
  | tar -x -C "$SIGNER_ROOT"
export OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM="..."
docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=16m \
  -e OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM \
  -v "$SIGNER_ROOT:/signer:ro" -v "$OUT/signing-state:/state:rw" \
  -w /signer "$TOOLCHAIN" \
  node scripts/linux-port/sign-linux-release-requests.mjs \
    --state-dir /state --version "$VERSION" \
    --git-commit "$COMMIT" --architecture "$ARCH"
unset OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM

docker run --rm \
  -e OPENBURNBAR_LINUX_RELEASE_OUT=/workspace/.linux-shard \
  -e OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID \
  -e OPENBURNBAR_FIREBASE_API_KEY \
  -e OPENBURNBAR_LINUX_APP_CHECK_APP_ID \
  -v "$PWD:/workspace" -w /workspace "$TOOLCHAIN" \
  node scripts/linux-port/build-linux-release.mjs \
    --architecture-shard --phase finalize --version "$VERSION"
docker run --rm -e OPENBURNBAR_LINUX_RELEASE_OUT=/workspace/.linux-shard \
  -v "$PWD:/workspace" -w /workspace "$TOOLCHAIN" \
  node scripts/linux-port/smoke-linux-packages.mjs --architecture-shard
```

Run prepare and finalize in the pinned Linux toolchain container as root; native
archive inventory intentionally rejects non-root extraction because it cannot
prove the package's installed uid/gid contract. Release CI is the canonical
invocation. It runs the prepare container without the private key, exits it,
materializes the signer from the exact release commit, and gives a separate
networkless, read-only, capability-free signer container only the three
canonical request files. Final Tauri bundling and package verification then run
without the key. The key never enters npm, Tauri, an archive extractor, or the
mutable build container.

The prepare phase compiles the Tauri executable and creates exact deb, rpm, and
AppImage signing requests. The isolated signer binds explicit version, commit,
and architecture inputs. Finalize rebuilds each native format with its detached
attestation, preflights archive member paths, extracts with libarchive's secure
path handling, and re-verifies exact bytes, Ed25519 signatures, authorized daemon
identity, manager metadata, modes, and absence of extra files before recording
the shard. Missing or mismatched inputs fail instead of emitting a candidate.

Run those three phases on native aarch64 and x86_64 hosts. CI uploads each hash-bound
`architecture-closure.json` and native smoke result, downloads both into
`.linux-shards/`, then runs:

```bash
OPENBURNBAR_LINUX_SHARDS_DIR="$PWD/.linux-shards" \
OPENBURNBAR_LINUX_RELEASE_OUT="$PWD/.linux-release" \
OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM="..." \
  node scripts/linux-port/assemble-linux-release.mjs \
  --version 1.2.3 --channel prerelease
```

The assembler is the only owner of the schema-3 package closure, checksums,
source archive, SBOM, VEX, provenance, artifact signatures, and signed public
feed. It rejects a missing architecture, type/architecture duplicate,
cross-commit shard, dirty shard, hash drift, filename collision, or incomplete
native smoke result.

## Install and update smoke

Architecture-shard smoke must inspect and install each native package, execute
the package-owned daemon launcher against the embedded Swift/SQLCipher runtime,
run the AppImage version path, and uninstall cleanly. Candidate certification
must additionally prove the painted GUI, long-running daemon health, and
update/rollback lifecycle.

```bash
node scripts/linux-port/smoke-linux-packages.mjs
```

The current first-release update path is blocked until a previous stable or
prerelease Linux artifact exists. The smoke script records that blocker instead
of inventing update success.

### In-app update availability

The packaged shell checks update availability through the native Tauri
`update_status` command. The renderer does not fetch or authenticate release
metadata. The command:

- fetches the fixed production URL
  `https://downloads.burnbar.ai/latest-linux.json` over
  HTTPS with bounded redirects, response sizes, and timeouts;
- verifies the detached Ed25519 signature with the public key compiled from
  `packaging/linux/openburnbar-linux-ed25519.pub.pem` and checks its pinned SPKI
  SHA-256 fingerprint;
- rejects unknown schema/product/platform/channel values, invalid semantic
  versions, missing architectures, invalid SHA-256 values, downgrade/replay
  candidates, and non-allowlisted artifact or signature URLs;
- chooses an artifact only after matching the installed package channel and
  CPU architecture; and
- returns typed `current`, `available`, `unavailable`, or `invalid` state to the
  renderer without exposing unverified feed fields.

Installation remains package-manager native. A validated update action may
open only an exact first-party BurnBar download path; it never self-mutates
distro-owned files. Apt/dnf/AppImage upgrade, restart, and rollback instructions
remain visible in the Updates and Support surfaces.

The public endpoint currently does not satisfy this contract, so the installed
application correctly reports **Update metadata rejected**. That is valid
fail-closed client evidence, not release/update closure. Promotion still
requires a signed two-architecture feed plus prior-version upgrade and rollback
evidence for every declared package channel.

## Signatures and provenance

Local signing verifier support uses the isolated
`sign-linux-release-requests.mjs` process with Ed25519 detached signatures.
Prepare and finalize reject `OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM` when it
is present. GitHub release CI additionally produces and verifies keyless
Sigstore/cosign bundles with
`id-token: write`. The workflow runs only from a pre-existing
`linux-v<version>` tag and uses this identity:

```text
https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-release.yml@refs/tags/linux-v<version>
```

Create the release commit and tag before running the workflow:

```bash
git tag linux-v<version> <release-commit>
git push origin linux-v<version>
```

The tag push starts the release automatically. A manual rerun must select the
same existing tag in GitHub's **Use workflow from** selector; dispatching from a
branch fails closed. The package version, checkout `HEAD`, source archive,
provenance predicate, Sigstore certificate identity, `gh release --target`, and
remote tag must all resolve to that one commit. Prerelease status is derived
from a SemVer prerelease suffix such as `linux-v0.2.0-rc.1`, not from a mutable
workflow input.

Linux releases explicitly use `--latest=false`; the repository-level latest
release remains the canonical macOS release rather than changing whenever a
platform-specific Linux tag is published.

Missing local signing material, OIDC, package-store credentials, or Flathub/AUR
publisher access is a named blocker. It is not a reason to publish weaker
metadata.

## Promotion gate

Strict verification:

```bash
node scripts/linux-port/verify-linux-release.mjs
```

This must exit 0 before `website/public/downloads/latest-linux.json` or any
public website/download metadata is added. The verifier checks:

- required artifacts and package metadata exist;
- each deb/rpm embeds the same signed installed manifest recorded by its native
  architecture shard;
- checksums match artifact bytes;
- SBOM, VEX, provenance predicate, and exact-commit source archive exist;
- detached signatures are recorded;
- package install/uninstall and update/rollback smoke logs exist;
- the worktree is clean and metadata binds to the release commit;
- the strict parity ledger has no blocked Tier A/B rows.

PRs may run the structural form while blockers are still being resolved:

```bash
node scripts/linux-port/verify-linux-release.mjs --allow-blocked
```

That mode is for review visibility only. It is not a promotion signal.

## Source offer and legal preflight

Linux releases inherit the AGPL source-offer bar from the macOS direct-download
lane:

```bash
bash scripts/ci/verify-agpl-compliance.sh
bash scripts/ci/build-corresponding-source-archive.sh
bash scripts/ci/verify-corresponding-source-archive.sh
```

The Linux assembler emits a commit-bound source archive for the current `HEAD`
and refuses a dirty worktree.

## Known blockers in this slice

- Native aarch64/x86_64 workflow construction is implemented, but a current
  two-architecture candidate and installed-session evidence have not yet been
  produced; the existing `.deb` remains shell-surface evidence.
- The latest V23/V24 validator evidence is for `1b62ec42bd75`, while the
  checkout moved to `1af805eb1878`; rerun validation at the release head.
- Detached Ed25519/minisign-compatible package signatures and GitHub
  Sigstore/cosign bundles are absent without release credentials/OIDC.
- A previous Linux stable/prerelease artifact does not exist, so update/rollback
  smoke cannot pass yet.
- the branded downloads origin does not yet serve the signed,
  two-architecture schema required by the native verifier.
- The active checkout is dirty with Linux-port implementation/evidence changes,
  so release metadata cannot bind to a clean release commit.
- The nightly matrix workflow exists, but current mission evidence does not
  include fresh GitHub artifacts for every named Linux desktop environment.
