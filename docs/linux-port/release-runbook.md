# Linux release runbook

The Linux release lane extends the macOS direct-download trust bar. Linux
artifacts must not be promoted from unsigned, untested, dirty, or synthetic
evidence.

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

- `VAL-SHELL-001` has a validator regression for fake daemon socket evidence.
- `VAL-CU-001`, `VAL-CU-003`, `VAL-MEDIA-001`, and related mobile/security rows
  have synthetic or unavailable real-surface evidence.
- The local Docker toolchain currently lacks AppImage tooling, cosign, minisign,
  syft, and Node 20+.
- A previous Linux stable/prerelease artifact does not exist, so update/rollback
  smoke is a first-release blocker.
