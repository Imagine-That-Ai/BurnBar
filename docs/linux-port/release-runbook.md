# Linux release runbook

The Linux release lane extends the macOS direct-download trust bar. Linux
artifacts must not be promoted from unsigned, untested, dirty, or synthetic
evidence.

The historical 2026-07-05 V24 foundation and V23 surface seal was captured at
`1b62ec42bd752cc8a6af578f034bf776c6ec3b97`. It is historical evidence only,
not current release closure. Release promotion always requires a fresh rerun
at the exact workflow `HEAD` plus the package, update,
signature/provenance, nightly, and clean-commit evidence below.

## Artifacts

Required release inputs and channel metadata:

- AppImage primary artifact.
- Debian package.
- RPM package.
- Signed apt repository metadata for both package architectures.
- Signed RPM repository metadata for both package architectures.
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
- Custom XDG drop-in example:
  [`../../packaging/linux/systemd/openburnbar-daemon.service.d/custom-xdg.conf.example`](../../packaging/linux/systemd/openburnbar-daemon.service.d/custom-xdg.conf.example).

Build locally:

```bash
set -euo pipefail
: "${OPENBURNBAR_LINUX_INSTALLED_MANIFEST_KEY_FILE:?set this to an operator-readable Ed25519 PEM file}"
: "${OPENBURNBAR_LINUX_FIREBASE_APP_ID:?set this to the dedicated Linux Firebase Web app id}"
: "${APP_CHECK_STANDARD_WEB_APP_IDS:?set this to the comma-separated website and console Firebase Web app ids}"
case "$(stat -c '%a' "$OPENBURNBAR_LINUX_INSTALLED_MANIFEST_KEY_FILE")" in
  400|600) ;;
  *) echo "installed-manifest signing key must have mode 0400 or 0600" >&2; exit 1 ;;
esac
unset OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM

export OPENBURNBAR_LINUX_RELEASE_OUT="$PWD/.linux-shard"
version=1.2.3

node scripts/linux-port/build-linux-release.mjs \
  --architecture-shard --prepare-only --version "$version"

node scripts/linux-port/build-native-linux-packages.mjs \
  --private-key-stdin \
  --firebase-app-id "$OPENBURNBAR_LINUX_FIREBASE_APP_ID" \
  --version "$version" \
  < "$OPENBURNBAR_LINUX_INSTALLED_MANIFEST_KEY_FILE"

node scripts/linux-port/build-linux-release.mjs \
  --architecture-shard --finalize-only --version "$version"

node scripts/linux-port/smoke-linux-packages.mjs --architecture-shard
```

`build-linux-release.mjs` intentionally has no one-pass mode. Prepare rejects
the signing-key environment variable, builds all Swift, Cargo, npm, Tauri, and
AppImage inputs with a scrubbed environment, and writes a commit/version/
architecture/hash-bound `architecture-preparation.json`. Only the dedicated
native-package signer receives the key, through stdin or `--private-key-file`;
it does not export key bytes to `dpkg-deb`, `tar`, or `rpmbuild`. The preparation
receipt contains a canonical root over every generated binary, runtime tree,
source asset, and lifecycle script. The signer verifies that root before key
loading, remeasures it after deb/rpm construction, verifies the extracted final
RPM payload, and emits a signed receipt over both package hashes. Finalize also
rejects the key environment variable and refuses a missing, failed, stale,
mutated, substituted, or unauthentic preparation/package receipt. This ordering
is a security boundary, not an optional local optimization.

Run that sequence on native aarch64 and x86_64 hosts. CI uploads each hash-bound
`architecture-closure.json` and native smoke result, downloads both into
`.linux-shards/`, then runs:

```bash
set -euo pipefail
: "${OPENBURNBAR_LINUX_INSTALLED_MANIFEST_KEY_FILE:?set this to the Ed25519 PEM file}"
unset OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM
OPENBURNBAR_LINUX_SHARDS_DIR="$PWD/.linux-shards" \
OPENBURNBAR_LINUX_RELEASE_OUT="$PWD/.linux-release" \
node scripts/linux-port/assemble-linux-release.mjs \
  --private-key-stdin --version 1.2.3 --channel prerelease \
  < "$OPENBURNBAR_LINUX_INSTALLED_MANIFEST_KEY_FILE"
```

The assembler creates the schema-3 package closure, checksums, source archive,
SBOM, VEX, provenance, artifact signatures, and signed public feed. The later
repository finalizer may add only hash-bound repository closure and lifecycle
records to that graph. Assembly rejects a missing architecture, type/architecture duplicate,
cross-commit shard, dirty shard, hash drift, filename collision, or incomplete
native smoke result.

### Signed apt and RPM repositories

Repository construction is a separate credential boundary and runs **after**
the two-architecture assembler. It consumes the already-verified aggregate
release rather than rebuilding package inputs. Before the first candidate,
provision a recoverable production OpenPGP identity: commit its public key path,
primary fingerprint, and exact signing-key/subkey fingerprint to
`packaging/linux/distribution-channels.json`, change
the signing record from `unconfigured` to its configured state, and configure
the matching private key in GitHub as
`OPENBURNBAR_LINUX_REPOSITORY_GPG_PRIVATE_KEY`. Until then the production
configuration deliberately fails closed. Locally, keep the armored private key
in a mode-`0400` or mode-`0600` file and pass it only through stdin or
`--private-key-file`:

The committed policy requires a signing-capable EdDSA/ECDSA key or RSA key of
at least 3072 bits. The selected signing key or subkey and its expiration are
bound into the repository closure. Both the primary key and selected signing
key must remain valid through the seven-day apt metadata window plus a further
30 days; revoked, disabled, weak, non-signing, near-expiry, and ambiguous keys
are rejected before repository construction.

```bash
set -euo pipefail
: "${OPENBURNBAR_LINUX_REPOSITORY_GPG_KEY_FILE:?set this to the repository GPG private-key file}"
case "$(stat -c '%a' "$OPENBURNBAR_LINUX_REPOSITORY_GPG_KEY_FILE")" in
  400|600) ;;
  *) echo "repository signing key must have mode 0400 or 0600" >&2; exit 1 ;;
esac

OPENBURNBAR_LINUX_RELEASE_OUT="$PWD/.linux-release" \
node scripts/linux-port/build-linux-repositories.mjs \
  --private-key-stdin --version 1.2.3 --channel prerelease \
  < "$OPENBURNBAR_LINUX_REPOSITORY_GPG_KEY_FILE"

OPENBURNBAR_LINUX_RELEASE_OUT="$PWD/.linux-release" \
node scripts/linux-port/verify-linux-repositories.mjs \
  --version 1.2.3 --channel prerelease

OPENBURNBAR_LINUX_RELEASE_OUT="$PWD/.linux-release" \
OPENBURNBAR_LINUX_REPOSITORY_VERSION=1.2.3 \
OPENBURNBAR_LINUX_REPOSITORY_CHANNEL=prerelease \
bash scripts/linux-port/verify-linux-repository-lifecycle.sh

OPENBURNBAR_LINUX_RELEASE_OUT="$PWD/.linux-release" \
node scripts/linux-port/finalize-linux-repositories.mjs \
  --version 1.2.3 --channel prerelease
```

The builder writes `repositories/apt/`, `repositories/rpm/`, and the aggregate
`repositories/repository-closure.json` below
`$OPENBURNBAR_LINUX_RELEASE_OUT`. Apt metadata includes architecture-specific
package indices plus a signed `Release`, `InRelease`, and `Release.gpg`. RPM
package copies are signed with the same OpenPGP identity before `createrepo_c`
builds the index so client configuration can enforce both `gpgcheck=1` and
`repo_gpgcheck=1`; the detached repository signature covers the final
`repodata/repomd.xml`. The source package-set root maps those repository copies
back to the immutable release closure. The verifier checks both formats without
the private key, pins the configured public key and full fingerprint, and
rejects missing architectures, version/channel drift, unexpected files,
package/root drift, stale signatures, or closure mutation.
The apt `Release` and `InRelease` documents enable Acquire-By-Hash and carry a
signed `Valid-Until` exactly 168 hours after their signed `Date`; the verifier
rejects a missing, expired, shortened, or extended horizon. RPM primary
metadata is checksum-addressed, and the verifier follows `repomd.xml` through
the primary index to the exact signed package bytes.

The lifecycle verifier serves the generated repository from a read-only
container mount, installs and removes through clean Ubuntu apt and Fedora dnf
clients for both release architectures, and writes `repository-lifecycle.json`
bound to the signed repository-closure hash.
Finalization refuses missing or failed lifecycle proof and binds both the
repository closure and lifecycle receipt into the package closure and
provenance predicate. A metadata-only build or archive inspection is not
lifecycle evidence.

Use this publication order so a client can never observe signed metadata that
references an unavailable package:

1. Upload all update artifacts and Ed25519 signatures to the immutable
   `linux/releases/linux-v<version>/` R2 prefix; verify every public byte.
2. Upload versioned apt `pool/` and RPM package objects.
3. Upload generated indices and non-root repository metadata.
4. Publish apt `Release.gpg` before `Release`/`InRelease`, and the RPM detached
   signature before `repomd.xml`, so an authenticated pointer never precedes
   its signature.
5. Publish `repository-closure.json.asc` and then
   `repository-closure.json` last, after every referenced repository byte.
6. Download the public repository into a clean directory, rerun
   `verify-linux-repositories.mjs`, then perform clean install, upgrade,
   rollback, and uninstall tests on every declared architecture.
7. Publish and verify `latest-linux.json`; only then create the public GitHub
   release as a secondary release surface.

R2 object puts are not a transactional multi-object operation. Apt clients use
the single signed `InRelease` activation document and update artifacts use one
feed document pointing only at immutable versioned bytes. RPM's conventional
`repomd.xml` plus `repomd.xml.asc` pair still cannot be switched atomically on
a plain R2 custom domain. The metadata-last order fails closed, but an
interrupted pointer upload may require an operator rerun. Stable promotion
therefore remains blocked until a Worker/KV (or equivalent) versioned-snapshot
activation layer proves one-switch activation and rollback under interruption.

Source-level repository construction and verification are not channel
promotion. Do not add apt/dnf install copy until the signed public copy and
package-manager lifecycle evidence pass. The AUR recipe and Flatpak manifest
remain explicitly **unpromoted**: neither may appear in public installation
copy until its recipe/sandbox contract, publisher credential, and installed
lifecycle have independent evidence.

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

Installed-file manifests require an Ed25519 signature during the isolated
native-package signer phase above. Never export
`OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM` while running build preparation or
finalization; both commands reject it. Aggregate release/feed detached signing
is a later assembler-only credential boundary using the same stdin/file-only
custody rule; the assembler rejects the legacy key environment and scrubs all
Git, SBOM, and VEX child-process environments. GitHub release CI must
additionally produce keyless Sigstore/cosign bundles with `id-token: write` and
identity:

```text
https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-release.yml@refs/tags/linux-v<version>
```

Apt/RPM repository metadata uses the separate OpenPGP repository identity
declared in `packaging/linux/distribution-channels.json`. CI supplies the
armored private key from `OPENBURNBAR_LINUX_REPOSITORY_GPG_PRIVATE_KEY`; the
builder must prove that its public fingerprint exactly matches the configured
committed fingerprint before it signs anything. The checked-in production
configuration currently has `status: unconfigured`, `publicKey: null`,
`fingerprint: null`, and `provisioning: required`, which is an intentional
deployment blocker rather than a test key or unsigned fallback. This identity
does not replace the Ed25519 artifact/feed signatures or Sigstore provenance.

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
- checksums match artifact bytes;
- SBOM, VEX, provenance predicate, and source archive exist;
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
- The latest historical V23/V24 validator evidence is for `1b62ec42bd75`;
  rerun validation at the exact release workflow `HEAD`.
- Detached Ed25519/minisign-compatible package signatures and GitHub
  Sigstore/cosign bundles are absent without release credentials/OIDC.
- Signed apt/RPM repository construction is source-implemented, but no public
  repository copy or clean package-manager install/upgrade/rollback matrix has
  been captured for the exact candidate. The repository GPG private key must
  be provisioned as `OPENBURNBAR_LINUX_REPOSITORY_GPG_PRIVATE_KEY` before CI can
  produce a signed closure.
- Apt metadata intentionally expires after seven days. No scheduled metadata
  refresh workflow exists yet, so public channel copy and stable promotion must
  remain blocked until refresh uses the same closure/key policy and proves
  interruption-safe activation before the prior `InRelease` expires.
- AUR and Flatpak remain unpromoted pending publisher credentials, a corrected
  release-bound AUR recipe, Flatpak portal/keyring policy proof, and installed
  lifecycle evidence.
- A previous Linux stable/prerelease artifact does not exist, so update/rollback
  smoke cannot pass yet.
- the branded downloads origin does not yet serve the signed,
  two-architecture schema required by the native verifier.
- The active checkout is dirty with Linux-port implementation/evidence changes,
  so release metadata cannot bind to a clean release commit.
- The nightly matrix workflow exists, but current mission evidence does not
  include fresh GitHub artifacts for every named Linux desktop environment.
