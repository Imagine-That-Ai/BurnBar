# VM E2E Evidence — OpenBurnBar Linux (UTM)

**Date:** 2026-07-09  
**Host:** openburnbar-linux / Ubuntu 24.04 aarch64  
**Control:** SSH `burnbar@192.168.64.5` + `utmctl exec`

## Product parity (live)

| Check | Result |
|---|---|
| Branch daemon | Installed `/usr/local/bin/openburnbar-daemon` |
| AF_UNIX health | ok, `gatewayEnabled=true`, `:8317` |
| CU pending (no params) | `requests:[]` |
| Gateway `/v1/health` | ok, `platform=linux` |
| `/v1/models/catalog` | `catalog=true`, n=67 |
| Pensieve | configured |
| Secret Service | secret-tool store/lookup ok |
| Desktop unit tests | 375 pass |
| Strict parity ledger | `productParityClaim: true` |
| Strict release verify | `passed: true` |

Evidence: `branch-daemon/live-reverify.json`, `branch-daemon/gateway-e2e.json`
