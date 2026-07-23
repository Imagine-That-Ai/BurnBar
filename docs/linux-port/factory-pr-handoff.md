# Linux release factory PR handoff

## Summary

This handoff packages the Linux peer as reviewable release infrastructure **and**
tracks the mission-002 full macOS parity foundation work.

It does **not** claim full macOS product parity or public Linux release
readiness.

Current facts (2026-07-13):

- A public signed aarch64 **prerelease** exists (`linux-v0.1.0`).
- Full macOS parity is **not** complete — see
  [`FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md`](FULL_PARITY_IMPLEMENTATION_PLAN_2026-07-09.md)
  and [`full-macos-parity-audit-2026-07-09.md`](full-macos-parity-audit-2026-07-09.md).
- `parity-ledger.json` semantics set `productParityClaim: false`. Historical
  mission-001 rows are `scope: historical-infrastructure`. Product foundation
  rows use `scope: product-parity`.
- Public `https://burnbar.ai/latest-linux.json` must be real JSON before
  promotion; HTML SPA fallback is a hard update-feed blocker.
- The current review stack includes PR #1684 (exact persisted chat threads and
  safe loaded-message export), #1683 (reduced-motion/contrast/forced-colors
  accessibility contracts), #1682 (macOS/Linux differential oracle), #1681
  (approval-bound Browser Computer Use actions), #1680 (bounded database code
  inspection), and #1679 (native startup/deep-link handoff). These are source
  slices; none substitutes for the current-head installed receipts.

## Review map

1. Phase 0 reanchor evidence:
   - `docs/linux-port/evidence/mission-002-reanchor/**`
   - `scripts/linux-port/validate-parity-ledger.mjs`
   - `scripts/linux-port/check-linux-update-feed.mjs`
2. Path / parser / token / dashboard foundation:
   - `apps/linux-desktop/src/linuxPaths.ts`
   - `apps/linux-desktop/src/providerPathRegistry.ts`
   - `apps/linux-desktop/src/dashboard/**`
   - `apps/linux-desktop/src/styles/tokens.css` + `skins.css`
   - `OpenBurnBarCore/.../OpenBurnBarLinuxPaths.swift`
3. Bridge contract:
   - `apps/linux-desktop/src-tauri/src/lib.rs`
   - `apps/linux-desktop/src/tauriBridge.ts`
4. Release metadata (unchanged promotion blockers):
   - `packaging/linux/**`
   - `scripts/linux-port/verify-linux-release.mjs`

## Validation matrix

| Target | Command | Expected state |
|---|---|---|
| Ledger structure | `node scripts/linux-port/validate-parity-ledger.mjs --allow-blocked` | Pass; `productParityClaim: false` |
| Update feed | `node scripts/linux-port/check-linux-update-feed.mjs --allow-missing` | Fail closed on HTML body; soft on 404 |
| Docs | `node scripts/linux-port/check-linux-docs.mjs` | Pass |
| Desktop tests | `npm test --prefix apps/linux-desktop` | Pass |
| Desktop types | `cd apps/linux-desktop && npx tsc --noEmit` | Pass |
| Desktop build | `npm run build --prefix apps/linux-desktop` | Pass, no CSS syntax warning |
| Release promotion | `node scripts/linux-port/verify-linux-release.mjs` | Fail until packages, signatures, clean commit, feed |

## Packaging install contract (203/EXEC prevention)

| Path on disk | Source |
|---|---|
| `/usr/libexec/openburnbar-daemon-launch` | `packaging/linux/openburnbar-daemon-launch.sh` |
| `/usr/lib/systemd/user/openburnbar-daemon.service` | `packaging/linux/openburnbar-daemon.service` |
| `/usr/bin/openburnbar-daemon` | release daemon artifact |
| `/usr/share/applications/dev.openburnbar.OpenBurnBar.desktop` | `packaging/linux/openburnbar.desktop` |

Install paths are wired in:

- Arch release template `packaging/linux/aur/PKGBUILD.in`
- Tauri `apps/linux-desktop/src-tauri/tauri.conf.json` `bundle.linux.{deb,rpm,appimage}.files`
- `packaging/linux/release-manifest.json` `tailMetadata.daemonLaunchScript` + `installPaths`

Custom `XDG_DATA_HOME` / support dir under `ProtectHome=read-only` requires a
systemd drop-in (see `custom-xdg.conf.example`). Do not put
`OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS` in `daemon.env` — the launch script
refuses world-writable prefixes.

## Named blockers

- **Full product parity** is incomplete (see plan Phases 3–6).
- `VAL-RELEASE-001`…`004`: packages, smoke, signatures, provenance, update feed.
- Public `latest-linux.json` must not be HTML.
- Do not set `semantics.productParityClaim: true` until product rows are proven
  at the release head with fresh evidence.

## Rollback and containment

- Do not add `website/public/downloads/latest-linux.json` until strict release
  verification exits 0.
- Keep historical mission-001 ledger rows as infrastructure history; do not
  silently rewrite them to product-ready without re-running evidence.

## Factory entrypoints

```bash
make release-linux   # config + packaging sync + docs + desktop tests + ledger + feed unit tests
make linux-matrix    # local DE probe → mission-002 matrix artifacts + blocked.json
```

## Cross-agent receipt

- Saw mission-001 historical ledger all-ready overclaim risk and invented-RPC risk.
- Reaction: reanchor + foundation (paths, parser registry, tokens, dashboard,
  bridge contracts) with VAL product rows and `productParityClaim: false`.
- Status: Phase 0–2 complete; Phase 3–6 in progress (chat depth, production
  auth/device proof, Computer Use/Mercury/SmartHub routes, input methods, and
  the installed matrix).
- Release promotion still blocked (`productParityClaim: false`, packages/feed).
- Next owner: live multi-DE matrix proof + package artifacts for VAL-RELEASE-001.
