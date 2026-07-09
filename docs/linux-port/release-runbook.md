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

Build locally:

```bash
node scripts/linux-port/build-linux-release.mjs
```

The script writes package closure, checksums, SBOM, VEX, provenance predicate,
source archive, and draft update metadata under
`docs/linux-port/evidence/mission-001-release/`.

## Install and update smoke

Package smoke must prove install, launch, uninstall, and update/rollback.

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

- fetches the fixed production URL `https://burnbar.ai/latest-linux.json` over
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

Local signing verifier support is implemented with Ed25519 detached signatures
when `OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM` is present. GitHub release CI
must additionally produce keyless Sigstore/cosign bundles with `id-token: write`
and identity:

```text
https://github.com/Imagine-That-Ai/BurnBar/.github/workflows/linux-release.yml@refs/tags/v<version>
```

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

The Linux build script also emits a source archive for the current `HEAD`. If
the worktree is dirty, the archive is evidence-only and cannot be promoted.

## Known blockers in this slice

- AppImage and RPM release artifacts have not been produced from the active
  checkout; the existing `.deb` is shell-surface evidence, not full release
  package closure.
- The latest V23/V24 validator evidence is for `1b62ec42bd75`, while the
  checkout moved to `1af805eb1878`; rerun validation at the release head.
- Detached Ed25519/minisign-compatible package signatures and GitHub
  Sigstore/cosign bundles are absent without release credentials/OIDC.
- A previous Linux stable/prerelease artifact does not exist, so update/rollback
  smoke cannot pass yet.
- `https://burnbar.ai/latest-linux.json` does not yet serve the signed,
  two-architecture schema required by the native verifier.
- The active checkout is dirty with Linux-port implementation/evidence changes,
  so release metadata cannot bind to a clean release commit.
- The nightly matrix workflow exists, but current mission evidence does not
  include fresh GitHub artifacts for every named Linux desktop environment.
