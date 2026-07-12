# Branch daemon E2E — OpenBurnBar Linux (UTM)

**Date:** 2026-07-09T18:01:22Z  
**Build ID:** `90d0eb3d55c4f8f1f4879f0d6b86439ecdc75610`  
**Binary:** `/usr/local/bin/openburnbar-daemon` (branch guest build)  
**Runtime:** packaged `/opt/openburnbar/lib/swift` (Swift 6.1 libs)

## Green

| Check | Result |
|---|---|
| AF_UNIX `daemon.health` (cli peer) | ok, `gatewayEnabled=true`, `:8317` |
| AF_UNIX `daemon.config.get` (app peer) | ok snapshot |
| AF_UNIX `daemon.computer_use.approval.pending` | `requests:[]` |
| Gateway `/v1/health` (auth) | ok, `platform=linux` |
| Gateway `/v1/models` | 67 entries |
| Gateway `/v1/models/catalog` | `catalog=true`, `platform=linux`, n=67 |
| Pensieve | `pensieve_watcher_configured root_count=1` |
| Packaged `LD_LIBRARY_PATH` only | no segfault |

## Build notes

- Swift 6.1 link requires `-Xlinker --allow-shlib-undefined` (Observation → `swift::threading::fatal` missing from shared Core).
- Branch binary requires Swift 6.1 runtime; `/opt/openburnbar/lib/swift` was synced from the 6.1 toolchain on this VM.
- CU pending accepts missing `params` (Linux peer probes omit them).
- Prebuilt backup: `/usr/local/bin/openburnbar-daemon.1.0.29.prebuilt.bak`

## Vs prebuilt 1.0.29

| Surface | Prebuilt | Branch |
|---|---|---|
| `/v1/models/catalog` | 404 not found | 200 `catalog=true` n=67 |
| `/v1/models` | empty without credentials | 67 seeded models |
| CU pending (no params) | empty list (older build) | empty list after params-optional fix |

## Remaining for absolute full-parity close

1. Provider credentials for live chat completion
2. AppImage/deb/rpm + signatures + public `latest-linux.json`
3. Multi-route AT-SPI screenshot matrix
4. Ship 6.1 runtime libs in release packaging (not just VM-local rsync)
