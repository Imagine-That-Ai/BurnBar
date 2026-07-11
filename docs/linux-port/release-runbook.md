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

Use this publication transaction so an interrupted upload, stale publisher, or
failed cutover cannot expose a partial generation:

1. Run `setup-linux-downloads-r2.sh --provision-only`. It creates or inspects
   the bucket and custom domain, then deploys two separately named control
   planes: the upload Worker on `linux/repository-upload/*` plus
   `linux/repository-preview/*`, and the activation Worker on
   `linux/repository-admin/*`. The activation Worker also guards the raw
   repository and channel-feed pointer object paths. It requires distinct
   upload and activation tokens. It does not claim apt, RPM, or public feed
   routes.
2. Run `upload-linux-downloads-r2.sh`. It uploads release artifacts, detached
   signatures, and the signed feed draft under the create-only
   `linux/releases/linux-v<version>/` prefix; uploads shared checksum-addressed
   package/index leaves; uploads the complete repository below
   `linux/repository-snapshots/<channel>/<closure-sha256>/`; and byte-verifies
   every operation. Objects with trusted SHA-256 metadata must match it. A
   legacy object without metadata is adoptable only when it is at most 8 MiB
   and an exact byte hash succeeds; unknown large objects and drift fail `409`.
3. Set `OPENBURNBAR_LINUX_REPOSITORY_PREVIEW_SNAPSHOT` to the closure SHA-256
   and run the lifecycle verifier. The preview route reads that immutable
   snapshot without an activation pointer, so clean apt/dnf install and remove
   on both architectures must pass before public routing changes.
4. Run `activate-linux-repository.mjs --yes`. The client reads the current
   snapshot, generation, and ETag, writes a local intent receipt before any
   mutation can be attempted, and sends all three as one compare-and-swap
   identity. The control Worker validates the full target closure, signature
   presence, minimum apt validity, required roots, and every object digest. An
   object larger than 8 MiB must carry matching upload-time R2 SHA-256 custom
   metadata. The Worker then performs one conditional R2 pointer write. Stale,
   delayed, ABA, and concurrent publishers receive `409` without moving the
   active generation. An ambiguous HTTP result is reconciled from the durable
   intent receipt and live pointer state by compensation.
5. Run `setup-linux-downloads-r2.sh --deploy-only` to claim only the apt and RPM
   serving routes. This happens after activation so first deployment leaves the
   prior direct-R2 routes untouched until the candidate has passed preview.
   Mutable metadata, source/repo files, and channel-qualified bootstrap keys are
   resolved through the active pointer; checksum-addressed leaves stay shared.
6. Run `verify-linux-public-repository.mjs` and the public lifecycle verifier.
   Both exact-compare local bytes and require the expected
   `X-OpenBurnBar-Repository-Snapshot` header on every pointer-routed object.
7. Run `drill-linux-repository-rollback.mjs`. With a retained prior generation,
   it observes fresh CAS identity before each mutation, rolls back, verifies apt
   plus both RPM architectures, reactivates the candidate, and proves the final
   candidate state. First activation records an explicit no-prior skip. If a
   first-cutover transaction later fails, authenticated deactivation restores
   the pre-cutover direct-R2 repository paths. Stable also restores the legacy
   raw root-feed paths; prerelease and nightly have no legacy feed alias and
   return an ordinary headerless `404`. The legacy feed fallback serves only
   the untouched raw keys and never the versioned candidate upload. If
   a retained rollback generation has expired or otherwise cannot be restored,
   compensation deactivates the candidate with a `disabled` tombstone so no
   unverified snapshot remains available.
8. Run `publish-linux-update-feed-r2.sh --publish-only`. The control Worker
   verifies immutable feed bytes, the exact 64-byte Ed25519 signature against
   the compiled official SPKI key/fingerprint, every signed artifact's R2 size
   and SHA-256 custom metadata, and the exact repository generation, pointer
   ETag, channel, version, and source commit before one channel-scoped
   feed-pointer CAS. Stable, prerelease, and nightly have independent pointer
   generations and each retains its own prior signed descriptor, so an
   interleaved publication cannot consume another channel's rollback state. Run
   `setup-linux-downloads-r2.sh --feed-only` only after publication succeeds,
   then run `--verify-only`. The feed Worker rechecks the repository pointer
   and channel feed pointer before and after every read and returns `503` if
   either binding changed. Stable is served at `/latest-linux.json`; prerelease
   and nightly use `/linux/update/<channel>/latest-linux.json`. Verification
   requires the exact snapshot and feed-generation headers on both feed and
   signature responses in addition to byte and cryptographic equality.
9. Preserve root-generated upload, activation, and feed receipts in place;
   copy runner evidence receipts into `sidecars/`. Materialize and attest the
   published `latest-linux.json` filename, then Sigstore-attest every receipt
   with the release provenance predicate. Immediately before draft creation
   and after publication, re-verify the authenticated repository/feed pointers
   and exact public bytes. Download every draft and published GitHub asset and
   require its basename, size, and SHA-256 to equal the local asset closure.
10. If any step after activation fails, discover draft and published GitHub
    releases independently, delete only the exact run-marker-owned immutable
    release ID, and require three consecutive dual-source absence observations.
    Then run `compensate-linux-repository-activation.mjs`. It restores
    and verifies the retained prior generation, rebinds the matching current or
    retained signed feed descriptor to the new repository generation/ETag,
    accepts an already-restored prior generation as contained, or deactivates
    when rollback is unavailable. First-cutover deactivation proves the legacy
    direct-R2 repository and feed routes are restored with no candidate
    snapshot/feed-generation header; later deactivation proves every mutable
    root returns `503`. A missing or
    `mutationAttempted: false` intent receipt is the only no-network
    compensation case. The workflow always fails the release after proving
    containment; an uncontained result is a separate hard failure.

### Scheduled metadata refresh

The release transaction and the metadata-refresh transaction share the
`linux-repository-release` concurrency group and never cancel a run in
progress. The refresh workflow is pinned to `refs/heads/main`, runs every six
hours, and may also be dispatched
for `stable`, `prerelease`, `nightly`, or all channels. It refreshes an active
channel when signed apt validity has 96 hours or less remaining. A manual
`force_refresh` bypasses only that time threshold; it cannot bypass signature,
lineage, immutable-byte, lifecycle, activation, feed-binding, or compensation
checks. The 48-hour critical threshold and the Worker's 24-hour activation
minimum leave explicit monitoring and rollback margins inside the seven-day
signed window.

The scheduled lane is metadata-only. It does not rebuild application packages,
create or edit a GitHub release, publish new update-feed bytes, deploy Worker
routes, or advance an application version. Its transaction is:

1. `inspect-linux-repository-freshness.mjs` authenticates control status, reads
   the exact active closure and `InRelease` through the immutable preview, and
   verifies their snapshot identity, OpenPGP signature, signed dates, and
   configured thresholds. A proven inactive channel is a no-op; malformed,
   unreachable, unsigned, expired, or inconsistent state fails the run.
2. `fetch-linux-repository-snapshot.mjs` reconstructs the closure-listed active
   snapshot into a new local directory and exact-compares every size and
   SHA-256. Before key loading, the workflow reconciles that closure digest
   with both authenticated status receipts and runs the independent repository
   verifier over the fetched signed parent. The repository OpenPGP private key
   is not available to any read or parent-verification phase.
3. `refresh-linux-repository-metadata.mjs` receives the private key only through
   stdin inside the repository toolchain container. It writes a schema-2
   closure chained to the active snapshot, advances only the signed apt
   `Release`, `InRelease`, and `Release.gpg` window, and preserves the version,
   source commit, package-set root, signing identity, RPM metadata, bootstrap
   files, `.deb` bytes, and already-signed `.rpm` bytes exactly.
4. The normal repository verifier and clean local apt/dnf lifecycle must pass.
   `upload-linux-repository-refresh.mjs` then create-only uploads the new
   closure-addressed snapshot, followed by a clean preview lifecycle on both
   architectures. Upload drift returns `409` and cannot change the active
   pointer.
5. `activate-linux-repository.mjs --mode refresh --yes` writes its durable intent
   before the snapshot/generation/ETag compare-and-swap. Refresh is legal only
   from an active snapshot with the same version and source commit and an exact
   closure lineage to that snapshot.
6. Activation changes the repository pointer identity, so the feed deliberately
   returns `503` until `rebind-linux-repository-feed.mjs --target current`
   conditionally rebinds the existing signed descriptor to the new repository
   generation and ETag. This operation does not rewrite or republish feed bytes.
7. The authenticated rebound feed pointer, live signed feed, exact public
   repository bytes, snapshot headers, and clean apt/dnf lifecycle pass before
   the workflow writes and keyless-Sigstore-attests its transaction manifest.
   The attested manifest, predicate, Sigstore bundle, operational receipts,
   activation receipt, and signed repository closure are then create-only
   uploaded beneath the snapshot and activation generation. Before the first
   upload, the local uploader runs `cosign verify-blob-attestation` over the
   exact transaction manifest and bundle with the committed predicate type,
   GitHub OIDC issuer, and `linux-repository-refresh.yml@refs/heads/main`
   certificate identity. It also proves every duplicated closure/activation
   field, input and receipt hash, size, predicate binding, immutable response
   identity, and ETag before writing its receipt.
   Any failure from activation onward runs
   `compensate-linux-repository-activation.mjs`, restores and verifies the prior
   snapshot and feed with fresh CAS identity, or disables mutable routes if a
   safe rollback is unavailable. A compensated run still fails and opens the
   standing `linux-repository-refresh` operations issue.

The workflow loads the activation token only in authenticated status/control
steps, the upload token only in the two create-only repository and evidence
upload steps, and the repository
OpenPGP key only in the signer step after the active snapshot is authenticated.
It uses GitHub OIDC for Sigstore evidence rather than a fourth long-lived key.
The immutable evidence namespace preserves the exact successful transaction;
the separately uploaded GitHub run artifact preserves failures and compensation
attempts. Neither source-level wiring nor an artifact by itself proves that the
Workers, secrets, DNS, schedule, or public repository are deployed.

The activation record is availability/routing state, not a new trust root.
Package managers still verify the pinned OpenPGP identity and signed metadata.
Shared checksum-addressed leaves let a client that fetched the old signed root
finish after activation. Separate RPM `repomd.xml` and detached-signature
requests can straddle a legitimate activation and fail closed transiently; a
retry resolves one complete retained generation. Rollback activates a retained,
unexpired snapshot with the same compare-and-swap contract. Do not delete an
active, previous, or still-reachable snapshot or shared leaf.
Normal promotion requires a strictly newer semantic version; rollback is a
separate mode limited to the active record's `previousSnapshotId`. Refresh is a
same-version operation limited to an exact metadata-only child of the active
snapshot. Deactivation is a control-plane containment operation, not a release
promotion.
Every bearer-token request is pinned to the exact
`https://downloads.burnbar.ai` production origin; operator-supplied alternate
origins fail before the credential is sent. The upload Worker receives only
`OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN`; the control Worker receives only
`OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN`; serving and feed Workers
receive neither. Never reuse the two control-plane credentials.

Bootstrap files are part of each immutable snapshot. Public key downloads use
channel-qualified aliases such as
`openburnbar-prerelease-archive-keyring.gpg` and
`RPM-GPG-KEY-openburnbar-prerelease`; the legacy channel-less aliases remain
stable-only compatibility routes. For OpenPGP rotation, first publish an
old-key-signed bridge generation that installs both the old and next public
keys, prove existing installed clients retain the next trust anchor, then sign
a later generation with the new subkey. Snapshot routing permits the bootstrap
bytes to change atomically, but stable rotation remains blocked until a reviewed
installed keyring update mechanism and overlap lifecycle have live proof.

Source implementation does not establish deployment truth. The metadata-only
builder, same-version refresh activation mode, feed rebind, compensation path,
and scheduled/manual workflow are source-ready. Stable promotion remains
blocked until the branded DNS/custom domain, scoped Cloudflare credentials,
separate upload and activation secrets, production repository OpenPGP identity,
exact candidate public copy, interruption/rollback/deactivation drill, and at
least one scheduled pre-expiry refresh all have live production evidence.

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

The fixed application URL is the stable-channel alias. Release tooling keeps
prerelease and nightly publication state isolated at channel-qualified URLs;
an in-app selector for those tracks remains a separate product-parity task and
must not be inferred from repository publication support.

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
- Apt metadata intentionally expires after seven days. The scheduled/manual
  metadata-only refresh, closure chaining, same-version activation, feed rebind,
  and compensation transaction are source-implemented. No production run has
  yet proven that the exact package/RPM bytes remain unchanged and the new
  signed closure activates before the prior `InRelease` expires; public channel
  copy and stable promotion remain blocked on that live evidence.
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
