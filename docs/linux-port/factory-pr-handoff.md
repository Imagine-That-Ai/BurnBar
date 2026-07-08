# Linux release factory PR handoff

## Summary

This handoff packages the Linux peer as reviewable release infrastructure:
package metadata, release artifact generation, fail-closed update metadata,
sidecars, provenance hooks, CI gates, nightly matrix, parity ledger, docs, and
release-blocker reporting.

It does not claim public Linux release readiness. V24 foundation and V23 surface
evidence passed at `1b62ec42bd752cc8a6af578f034bf776c6ec3b97`, but the checkout
later moved to `1af805eb1878cc5af8821ee35cac838c5ac473ee`. Promotion remains
blocked until validation is rerun at the release head and release package,
update, signing/provenance, nightly-matrix artifact, and clean commit evidence
exist.

## Review map

1. Release metadata and packaging templates:
   - `packaging/linux/release-manifest.json`
   - `packaging/linux/openburnbar.desktop`
   - `packaging/linux/autostart/openburnbar.desktop`
   - `packaging/linux/openburnbar-daemon.service`
   - `packaging/linux/aur/PKGBUILD`
   - `packaging/linux/flatpak/dev.openburnbar.OpenBurnBar.yml`
2. Release scripts:
   - `scripts/linux-port/build-linux-release.mjs`
   - `scripts/linux-port/smoke-linux-packages.mjs`
   - `scripts/linux-port/verify-linux-release.mjs`
   - `scripts/linux-port/validate-parity-ledger.mjs`
   - `scripts/linux-port/check-linux-docs.mjs`
3. CI workflows:
   - `.github/workflows/linux-pr-gate.yml`
   - `.github/workflows/linux-nightly.yml`
4. Documentation and parity:
   - `docs/linux-port/README.md`
   - `docs/linux-port/release-runbook.md`
   - `docs/linux-port/parity-ledger.json`
   - `docs/linux-port/parity-ledger.md`
   - `docs/linux-port/evidence/mission-001-release/active-checkout-v23-v24-evidence.json`
   - `docs/RELEASE_MACOS.md`
   - `docs/security/SUPPLY_CHAIN_PROVENANCE.md`
   - `CHANGELOG.md`

## Validation matrix

| Target | Command | Expected state |
|---|---|---|
| Release config | `node scripts/linux-port/validate-linux-release-config.mjs` | Pass |
| Ledger structure | `node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked` | Pass with blocked-row warnings |
| Ledger promotion | `node scripts/linux-port/validate-parity-ledger.mjs` | Fail until release/nightly Tier A/B blockers clear |
| Docs | `node scripts/linux-port/check-linux-docs.mjs` | Pass |
| Package build | `node scripts/linux-port/build-linux-release.mjs` | May fail while Tauri/AppImage toolchain is incomplete; logs are evidence |
| Release promotion | `node scripts/linux-port/verify-linux-release.mjs` | Fail until packages, smoke, signatures, provenance, clean commit, and ledger are green |

## Named blockers

- `VAL-RELEASE-001`: no AppImage/RPM release artifacts or install/update smoke
  proof exist yet; the current `.deb` is shell-surface proof only.
- `VAL-RELEASE-002`: no promotable `latest-linux.json` candidate exists, and
  update/rollback smoke has no previous Linux stable/prerelease artifact.
- `VAL-RELEASE-003`: local evidence lacks detached package signatures,
  Sigstore/cosign bundle, and a clean release commit binding.
- Current-head evidence drift: the last green V23/V24 seal is for `1b62ec42bd75`,
  while the checkout is now `1af805eb1878`.
- `VAL-CI-002`: the nightly workflow exists, but no fresh GitHub artifact set
  proves every named Linux desktop environment.
- `VAL-DOC-001`: docs are accurate as readiness/blocker docs, but the contract
  depends on `VAL-RELEASE-001`, which is still blocked.

## Rollback and containment

- Do not add `website/public/downloads/latest-linux.json` until strict release
  verification exits 0.
- Keep Linux release artifacts under evidence or GitHub Actions artifacts until
  promotion. Do not update website download copy as if Linux is public.
- If a partial package is generated, remove only that release evidence directory
  and rerun `build-linux-release.mjs`; product source changes are separate.

## Cross-agent receipt

- Saw current active-checkout V24/V23 foundation/surface seals and the older
  recovered-worktree release lane.
- Reaction: moved product rows to current active-checkout ready evidence and
  kept release/CI/doc closure rows fail-closed.
- Status: release infrastructure is reviewable; public promotion is blocked.
- Next owner: release lane produces AppImage/deb/rpm artifacts, signatures,
  update smoke, nightly artifacts, and strict verification from a clean commit.
