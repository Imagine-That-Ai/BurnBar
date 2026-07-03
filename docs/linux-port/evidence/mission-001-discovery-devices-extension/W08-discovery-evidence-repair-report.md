# W08 Discovery Evidence Repair

Lane: `W08DiscoveryEvidenceRepair`
Worktree: `/private/tmp/openburnbar-linux-mission-001`
Generated: 2026-07-03T13:32:03Z

## Summary

- CLI evidence is rerunnable from the mission worktree via linked `OpenBurnBarCLI` in Docker (`/workspace/OpenBurnBarDaemon/.build-linux-w08-gate-remediation/aarch64-unknown-linux-gnu/debug/OpenBurnBarCLI`).
- Parser/fixture proof is separate from live mDNS: `local-peer parse-fixture` on `avahi-parsable-fixture.txt` (not live browse/publish).
- Live Avahi browse/publish remains **blocked** when toolchain image lacks Avahi CLI and D-Bus (see `avahi-environment.txt`).

## Commands and exit codes

| Step | Exit | Artifact |
| --- | ---: | --- |
| `swift build --product OpenBurnBarCLI` (Docker) | 0 | `linux-compile-gate.txt` |
| OpenBurnBarCLI local-peer/devices transcript | see sections | `cli-linux-transcript.txt` |
| Avahi/DBus/hardware probe (toolchain container) | 0 | `avahi-environment.txt` |
| `OpenBurnBarCLI local-peer parse-fixture avahi-parsable-fixture.txt` | 0 | `avahi-parser-fixture-transcript.txt` |
| Extension focused tests (daemonClient + controller) | 127 | `extension-focused-tests.log` |

- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift` — `local-peer parse-fixture` evidence subcommand
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/Linux/BurnBarLinuxLocalPeerDiscovery.swift` — Avahi octal escape + quoted TXT parsing; parsable field indices
- `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/BurnBarLinuxLocalPeerDiscoveryTests.swift` — optional XCTest (full `swift test` graph blocked on unrelated daemon tests)
- `scripts/linux-port/run-discovery-devices-extension-evidence.sh` — fail-closed CLI path, expanded probes, separate live vs fixture evidence
- `docs/linux-port/evidence/mission-001-discovery-devices-extension/avahi-parsable-fixture.txt` — captured real Avahi line (fixture only)

## Blockers (fail-closed)

**Live mDNS / Avahi services:** avahi-browse not on PATH in toolchain image; avahi-publish-service not on PATH in toolchain image; D-Bus system bus socket missing (/run/dbus/system_bus_socket)

**Hardware / firmware lane:** PixelClock USB/UART and NetworkManager-dependent flashing not available in default toolchain container; see `pixelclock-firmware-lane-sample.json` and `cli-linux-transcript.txt` firmware-lane section.

## Contract notes

| Contract | Evidence | Status |
| --- | --- | --- |
| VAL-MDNS-001 | CLI advertise/disabled + parser fixture tests; live browse blocked without Avahi | Partial — parser/fixture improved; live mDNS blocked |
| VAL-DEVICE-001 | CLI pixel-clock discover/parity/firmware-lane | Partial — blocked rows when Avahi/hardware absent |
| VAL-IOT-001 | CLI cast status + parity | Partial — Avahi-dependent adapters blocked |
| VAL-EXTENSION-001 | XDG path samples + extension unit tests | Improved — paths + `alertDaemonUnreachable` |

## Artifact index

- `linux-compile-gate.txt`
- `cli-linux-transcript.txt`
- `avahi-environment.txt`
- `avahi-parser-fixture-transcript.txt`
- `avahi-parsable-fixture.txt`
- `mdns-metadata-sample.json`
- `parity-ledger-sample.json`
- `pixelclock-firmware-lane-sample.json`
- `linux-xdg-path-evidence.json`
- `extension-linux-path-sample.json`
- `extension-focused-tests.log`
