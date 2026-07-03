# Linux Local Discovery Parity Ledger

Scope: Zenith mission-001 worker lane for Linux local discovery, device adapters, PixelClock firmware attempt, and VS Code/Cursor extension daemon-health monitoring.

| Contract | Surface | Status | Evidence | Blocker |
|---|---|---:|---|---|
| VAL-MDNS-001 | OpenBurnBar Avahi advertisement metadata | Ready | `BurnBarLocalPeerMetadata` emits `_openburnbar._tcp` TXT keys `caps`, `gateway`, `peer`, `platform`, `proto`, `socket`; direct typecheck passed and test source covers privacy validation. | None |
| VAL-MDNS-001 | Avahi browse/resolve parser and teardown/conflict handling | Ready | `BurnBarAvahiBrowseParser`, `BurnBarAvahiRegistrationResult`, and `BurnBarAvahiLifecycleEvidence` handle resolved, removed, disabled, and name-collision transcripts. | Package-level Linux SwiftPM graph currently fails before these tests due unrelated pre-existing Insight/Pi exclusions; see evidence README. |
| VAL-DEVICE-001 | PixelClock mDNS discovery and HTTP control plans | Ready | `_http._tcp` AWTRIX fixture resolves to `/api/stats`, `/api/custom?name=openburnbar`, and `/api/notify` control plans. | No physical PixelClock in workspace; fixture-backed only. |
| VAL-DEVICE-001 | PixelClock firmware lane through NetworkManager DBus/libudev | Blocked | Firmware lane probes are explicit: `busctl introspect org.freedesktop.NetworkManager /org/freedesktop/NetworkManager`, `udevadm info --export-db`, serial scan, and firmware image check. | Linux container evidence: `busctl` absent, `udevadm` absent, `/run/dbus/system_bus_socket` missing, and no `/dev/ttyUSB*` or `/dev/ttyACM*`. |
| VAL-IOT-001 | SmartHub local-peer adapter | Ready | `_openburnbar._tcp` Avahi fixture builds `GET /local-peer/status` control plan. | No live device; fixture-backed only. |
| VAL-IOT-001 | Cast adapter | Ready | `_googlecast._tcp` Avahi fixture builds `GET /setup/eureka_info?options=detail` control plan. | No live Cast device; fixture-backed only. |
| VAL-IOT-001 | Home Assistant adapter | Ready | `_home-assistant._tcp` Avahi fixture builds `GET /api/` control plan. | No live Home Assistant device; fixture-backed only. |
| VAL-EXTENSION-001 | Linux extension daemon path resolution | Ready | `resolveOpenBurnBarDaemonRuntimePaths()` resolves `/run/user/<uid>/openburnbar/openburnbar-daemon.sock` and XDG state token files; Vitest coverage passed. | None |
| VAL-EXTENSION-001 | Extension daemon-health monitoring and alert utility | Ready | Controller test proves offline alert uses the Linux socket path, reconnect returns connected health, and direct `vscode.window.showError*` grep outside `alerting.ts` returns no matches. | None |
