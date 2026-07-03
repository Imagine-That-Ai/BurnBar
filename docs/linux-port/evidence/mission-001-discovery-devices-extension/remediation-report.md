# W08 Discovery / Devices / Extension — Remediation

Lane: `W08DiscoveryDevicesExtension` remediation pass.

## Root cause (first pass)

First pass used `swift run --skip-build OpenBurnBarCLI` against build path `.build-linux-w08-gate` without a linked `OpenBurnBarCLI` executable (`swift build --target` compiles modules but does not link the product executable).

## Fix

- Evidence runner: `scripts/linux-port/run-discovery-devices-extension-evidence.sh` builds `--product OpenBurnBarCLI` and invokes the linked binary inside Docker at `/workspace/OpenBurnBarDaemon/.build-linux-w08-gate-remediation/aarch64-unknown-linux-gnu/debug/OpenBurnBarCLI`.
- Linux path alignment: `OpenBurnBarLinuxPaths.supportDirectoryURL` defaults to `XDG_CONFIG_HOME/OpenBurnBar` (fallback `~/.config/OpenBurnBar`) to match extension `defaultBurnBarSupportDir()`.

## Commands

| Step | Exit |
| --- | --- |
| `swift build --build-path ... --product OpenBurnBarCLI` (Docker) | **0** |
| `OpenBurnBarCLI local-peer advertise-metadata --json` | see `cli-linux-transcript.txt` |
| `OpenBurnBarCLI local-peer disabled-state --json` | see `cli-linux-transcript.txt` |
| `OpenBurnBarCLI local-peer browse --json` | see `cli-linux-transcript.txt` |
| Avahi probe in Docker | see `avahi-environment.txt` |

## Artifacts

- `linux-compile-gate.txt` — build + binary attestation
- `cli-linux-transcript.txt` — CLI runtime transcript
- `linux-xdg-path-evidence.json` — XDG support/socket defaults
- `extension-linux-path-sample.json` — extension TS path defaults
- `mdns-metadata-sample.json` — sanitized TXT from CLI
- `parity-ledger-sample.json` — `devices parity --json`
- `avahi-environment.txt` — Avahi tool availability
- `remediation-report.md` — this report

## Contract status

| Contract | Status |
| --- | --- |
| VAL-MDNS-001 | **Improved** — CLI `advertise-metadata` / `disabled-state` runtime JSON; live browse exits 1 with precise Avahi blocker when tools absent |
| VAL-DEVICE-001 | **Improved** — `devices pixel-clock discover` / `parity` CLI transcript |
| VAL-IOT-001 | **Improved** — `devices iot cast status --json` transcript |
| VAL-EXTENSION-001 | **Improved** — XDG path evidence + existing `alertDaemonUnreachable` (unchanged) |

## Avahi environment

avahi-utils not installed on toolchain image (avahi-browse and avahi-publish-service missing from PATH)

## Tester follow-ups

- Swift unit: `BurnBarLinuxLocalPeerDiscovery.sanitizedTXT` excludes secrets/paths.
- Swift unit: Linux `BurnBarDaemonPaths.supportDirectoryURL` with `XDG_CONFIG_HOME`.
- Extension test: `defaultBurnBarSocketPath()` on `linux`.
