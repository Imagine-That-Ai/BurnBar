# VM E2E Evidence — OpenBurnBar Linux (UTM)

**Date:** 2026-07-09  
**Host:** openburnbar-linux / Ubuntu 24.04 aarch64

## Product parity (live)

| Check | Result |
|---|---|
| Branch daemon | installed + gateway :8317 |
| AF_UNIX health / CU pending | ok / `requests:[]` |
| `/v1/models/catalog` | `catalog=true` n=67 |
| Secret Service | secret-tool ok |
| Desktop tests | 375 pass |
| deb/rpm payload | daemon + launch + Swift runtime under `/opt/openburnbar/lib/swift` |
| Smoke package asserts | `package-smoke-summary.json` passed |
| VAL-DASHBOARD-004 | six-layout screenshot matrix |
| Strict ledger | `productParityClaim: true` |
| Strict release verify | `passed: true` |

Evidence: `branch-daemon/live-reverify.json`, `../smoke/`, `../dashboard-layouts/`, `../artifacts/`
