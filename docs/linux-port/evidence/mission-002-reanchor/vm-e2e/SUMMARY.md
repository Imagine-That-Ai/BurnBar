# VM E2E Evidence — OpenBurnBar Linux (UTM)

**Date:** 2026-07-09  
**Host:** openburnbar-linux / Ubuntu 24.04 aarch64  
**Control:** SSH `burnbar@192.168.64.5` + `utmctl exec`

## Branch daemon (current live)

See **[branch-daemon/SUMMARY.md](./branch-daemon/SUMMARY.md)** for the full green matrix.

| Check | Result |
|---|---|
| Daemon binary | Branch guest build `90d0eb3d…` at `/usr/local/bin/openburnbar-daemon` |
| AF_UNIX health | ok, `gatewayEnabled=true`, `:8317` |
| Gateway `/v1/health` | ok, `platform=linux` |
| `/v1/models` | 67 seeded models |
| `/v1/models/catalog` | **`catalog=true`** (prebuilt 1.0.29 was 404) |
| Peer auth | CLI + app identity probes work |
| Computer Use pending | `requests:[]` (params optional) |
| Pensieve | `root_count=1` |
| Secret Service | secret-tool store/lookup |
| Desktop app | process + X window |
| Guest unit tests | 375 pass |
| Guest vite build | pass |

## Prebuilt baseline (earlier same day)

Prebuilt 1.0.29 proved socket/gateway/desktop/tests; catalog route was 404 until branch rebuild.

## Remaining for absolute full-parity close

1. Provider credentials for live chat completion
2. AppImage/deb/rpm + signatures + public `latest-linux.json` (bundle Swift 6.1 runtime)
3. Multi-route AT-SPI screenshot matrix for every ROUTES id
