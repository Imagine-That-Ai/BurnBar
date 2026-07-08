# W08 Discovery Evidence Repair

Lane: `W08DiscoveryEvidenceRepair`
Worktree: `$WORKSPACE`
Generated: 2026-07-08T03:21:45Z

## Summary

- CLI evidence is rerunnable from the mission worktree via linked `OpenBurnBarCLI` in Docker (`/workspace/OpenBurnBarDaemon/.build-linux-w08-gate-remediation/aarch64-unknown-linux-gnu/debug/OpenBurnBarCLI`).
- Parser/fixture proof is separate from live mDNS: `local-peer parse-fixture` on `avahi-parsable-fixture.txt` (not live browse/publish).
- Live Avahi browse/publish now runs inside the evidence container with package-backed `avahi-daemon`, D-Bus, `avahi-publish-service`, and `avahi-browse`; raw transcripts are under `live-simulator/`.
- PixelClock/AWTRIX, Cast, SmartHub, and Home Assistant control/status checks run against accepted local simulator endpoints and product CLI surfaces.

## Commands and exit codes

| Step | Exit | Artifact |
| --- | ---: | --- |
| `swift build --product OpenBurnBarCLI` (Docker) | 0 | `linux-compile-gate.txt` |
| OpenBurnBarCLI local-peer/devices transcript | see sections | `cli-linux-transcript.txt` |
| Avahi/DBus/hardware probe (toolchain container) | 0 | `avahi-environment.txt` |
| `OpenBurnBarCLI local-peer parse-fixture avahi-parsable-fixture.txt` | 1 | `avahi-parser-fixture-transcript.txt` |
| Live Avahi/D-Bus + device/IoT simulator endpoints | 0 | `live-simulator/` |
| Extension focused tests (daemonClient + controller) | 0 | `extension-focused-tests.log` |

- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift` — `local-peer parse-fixture` evidence subcommand
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/BurnBarLinuxLocalPeerDiscovery.swift` — Avahi octal escape + quoted TXT parsing; parsable field indices
- `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarLinuxLocalPeerDiscoveryTests.swift` — optional XCTest (full `swift test` graph blocked on unrelated daemon tests)
- `scripts/linux-port/run-discovery-devices-extension-evidence.sh` — fail-closed CLI path, expanded probes, separate live vs fixture evidence
- `docs/linux-port/evidence/mission-001-discovery-devices-extension/avahi-parsable-fixture.txt` — captured real Avahi line (fixture only)

## Blockers (fail-closed)

**Live mDNS / Avahi services:** none when `live_simulator_exit_code=0`; inspect `live-simulator/avahi-publish-transcript.txt`, `live-simulator/raw-avahi-openburnbar.txt`, and `mdns-live-status.json`.

**Hardware / firmware lane:** PixelClock USB/UART and NetworkManager-dependent flashing not available in default toolchain container; see `pixelclock-firmware-lane-sample.json` and `cli-linux-transcript.txt` firmware-lane section.

## Contract notes

| Contract | Evidence | Status |
| --- | --- | --- |
| VAL-MDNS-001 | Live Avahi publish/browse + product parser decode + conflict/teardown proof | See `mdns-live-status.json` |
| VAL-DEVICE-001 | Product CLI PixelClock/AWTRIX discovery/control/status against simulator endpoint | See `device-iot-target-status.json` |
| VAL-IOT-001 | Product CLI Cast/SmartHub/Home Assistant discovery/control/status against simulator endpoints | See `device-iot-target-status.json` |
| VAL-EXTENSION-001 | XDG path samples + extension unit tests | Improved — paths + `alertDaemonUnreachable` |

## Artifact index

- `linux-compile-gate.txt`
- `cli-linux-transcript.txt`
- `avahi-environment.txt`
- `avahi-parser-fixture-transcript.txt`
- `avahi-parsable-fixture.txt`
- `mdns-live-status.json`
- `device-iot-target-status.json`
- `mdns-metadata-sample.json`
- `parity-ledger-sample.json`
- `live-simulator/product-cli-discovery-control-transcript.txt`
- `pixelclock-firmware-lane-sample.json`
- `linux-xdg-path-evidence.json`
- `extension-linux-path-sample.json`
- `extension-focused-tests.log`
