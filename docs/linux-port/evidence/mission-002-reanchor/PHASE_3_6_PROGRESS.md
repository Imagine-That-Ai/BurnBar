# Phase 3–6 progress + UTM VM E2E (2026-07-09)

## Control plane

- UTM VM **OpenBurnBar Linux** live at `192.168.64.5`
- SSH: `ssh -i ~/.ssh/openburnbar_linux_vm burnbar@192.168.64.5`
- Guest agent: `utmctl exec "OpenBurnBar Linux" --cmd …`
- Access doc: `docs/linux-port/UTM_VM_ACCESS.md`
- VM evidence: `docs/linux-port/evidence/mission-002-reanchor/vm-e2e/`

## Phase 3 — Daemon/core

| Item | Status | Proof |
|---|---|---|
| Pensieve inotify | Implemented + daemon logs `pensieve_watcher_configured root_count=1` | VM daemon log |
| POSIX switcher | Process + PATH profiles | Source + compile gate |
| Gateway models/catalog | **Live on branch daemon** `catalog=true` n=67 | `vm-e2e/branch-daemon/gateway-e2e.json` |
| Secrets fail-closed | Core tests + Secret Service store/lookup on GNOME | VM secret-tool |
| Peer auth AF_UNIX | Health/config/CU pending via app-named peer binary | `vm-e2e/branch-daemon/` |
| Guest Swift rebuild of daemon | **Done** Swift 6.1 + `--allow-shlib-undefined`; installed `/usr/local/bin/openburnbar-daemon` build `90d0eb3d…` | `vm-e2e/branch-daemon/SUMMARY.md` |

## Phase 4 — UI

| Item | Status | Proof |
|---|---|---|
| Routes CU / Mercury / SmartHub | Shipped | 375 unit tests on VM |
| Desktop running | `openburnbar-linux-desktop` PID + X window | xwininfo tree |
| Screenshots | Full desktop captures under `vm-e2e/screenshots/` | Files |
| Chat live gateway stream | Gateway up (`gatewayEnabled=true`); needs provider credentials for live stream | branch-daemon health |

## Phase 5 — Release

| Item | Status |
|---|---|
| `make release-linux` | Foundation gates |
| Launch script LD_LIBRARY_PATH + index DB | Fixed for real VM |
| Packaging path sync | Green |
| Strict package/sig/feed promotion | Still needs clean release commit + public JSON feed |

## Phase 6 — Matrix

| Item | Status |
|---|---|
| GNOME Ubuntu 24.04 aarch64 UTM | **Live** |
| secret-tool | **OK** |
| KWallet | N/A (GNOME) — recorded blocked |
| Display/Xorg | **OK** |
| Additional DEs | Not yet provisioned |

## Guest validation commands (latest)

```
npm test --prefix apps/linux-desktop   # 375 pass
npm run build                          # pass after design-tokens build
/opt/openburnbar/bin/openburnbar-linux-desktop daemon.health  # ok
```

## Remaining to call full parity complete

1. ~~Rebuild/install daemon from this branch on the VM~~ **Done** (see `vm-e2e/branch-daemon/`).
2. One provider credential for live chat stream proof.
3. Automate route screenshots (xdotool/AT-SPI) for all ROUTES.
4. Produce AppImage/deb/rpm + signatures → strict `verify-linux-release.mjs` green; bundle Swift 6.1 runtime into `/opt/openburnbar/lib/swift`.
5. Publish real `latest-linux.json` only after (4).
