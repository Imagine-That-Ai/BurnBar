# Linux release factory PR handoff

## Summary

This handoff packages the Linux peer as reviewable release infrastructure:
package metadata, release artifact generation, fail-closed update metadata,
sidecars, provenance hooks, CI gates, nightly matrix, parity ledger, docs, and
release-blocker reporting.

It does not claim public Linux release readiness. Promotion remains blocked
until prerequisite product regressions and external signing/provenance
credentials are resolved.

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
   - `docs/RELEASE_MACOS.md`
   - `docs/security/SUPPLY_CHAIN_PROVENANCE.md`
   - `CHANGELOG.md`

## Validation matrix

| Target | Command | Expected state |
|---|---|---|
| Release config | `node scripts/linux-port/validate-linux-release-config.mjs` | Pass |
| Ledger structure | `node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked` | Pass with blocked-row warnings |
| Ledger promotion | `node scripts/linux-port/validate-parity-ledger.mjs` | Fail until Tier A/B blockers clear |
| Docs | `node scripts/linux-port/check-linux-docs.mjs` | Pass |
| Package build | `node scripts/linux-port/build-linux-release.mjs` | May fail while Tauri/AppImage toolchain is incomplete; logs are evidence |
| Release promotion | `node scripts/linux-port/verify-linux-release.mjs` | Fail until packages, smoke, signatures, provenance, clean commit, and ledger are green |

## Named blockers

- `VAL-SHELL-001`: packaged shell proof used a fake daemon socket in validator
  evidence. Release packages cannot be promoted until a real daemon launch path
  is proven.
- `VAL-CU-001` and `VAL-CU-003`: Computer Use evidence includes blocked portal
  setup and synthetic panic-halt timing.
- `VAL-MEDIA-001`: media evidence is loopback/static and lacks live codec,
  backpressure, LAN/mobile/mac interop, and percentile timing.
- `VAL-MDNS-001`: Avahi parsing failed real escaped-name/TXT cases.
- External credentials/tooling: local environment lacks release Ed25519 signing
  key, GitHub OIDC/cosign runtime, AUR/Flathub publisher credentials, and a
  complete AppImage toolchain.

## Rollback and containment

- Do not add `website/public/downloads/latest-linux.json` until strict release
  verification exits 0.
- Keep Linux release artifacts under evidence or GitHub Actions artifacts until
  promotion. Do not update website download copy as if Linux is public.
- If a partial package is generated, remove only that release evidence directory
  and rerun `build-linux-release.mjs`; product source changes are separate.

## Cross-agent receipt

- Saw validator regressions for shell, Computer Use, media, mDNS, provider, and
  perf rows.
- Reaction: encoded them as blocked parity rows and made release promotion fail
  closed instead of weakening release metadata.
- Status: release infrastructure is reviewable; public promotion is blocked.
- Next owner: product-lane owners clear the prerequisite regressions; release
  lane reruns package/smoke/sign/provenance gates from a clean commit.
