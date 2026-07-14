# F2 privileged-input watchdog process

Date: 2026-07-14

WPD-0006 row: 27

Disposition: implementation complete; Windows-host promotion pending

## Production composition

`OpenBurnBar.ComputerUse.Watchdog` is an independent, self-contained Windows
process. The WinUI app probes an existing instance during startup, launches the
fixed packaged executable through the central child-process policy when absent,
and accepts readiness only after an authenticated health exchange. Failure is
redacted and fail-closed; no product credential is inherited by the process.

The watchdog owns the durable per-user
`%LOCALAPPDATA%\OpenBurnBar\privileged-input-kill.flag` and implements bounded
`activate`, `clear`, and `health` commands through the existing portable
`WatchdogServer`. The command frame is message-mode and capped at 4 KiB.

## Trust boundary

The local channel uses a SID-derived, per-user pipe name and an owner-only,
non-inheriting DACL. `FILE_FLAG_FIRST_PIPE_INSTANCE` rejects name squatting and
remote pipe clients are rejected. Before either side accepts application data:

1. the server resolves the kernel-attested client PID and impersonated SID;
2. both sides validate the peer executable and every loaded module with
   `WinVerifyTrust` plus trusted-directory confinement;
3. the main image must have the exact `Imagine That AI LLC` publisher subject;
4. both sides complete a signed-nonce mutual handshake with a persisted,
   non-exportable Microsoft Platform Crypto Provider P-256 key.

The `OPENBURNBAR_PIPE_AUTH_DISABLE` developer bypass is compiled out of Release
builds through `RELEASE_HARDENED`. Signer resources are disposed after every
handshake. Errors expose no SID, path, nonce, certificate, or key material in
application diagnostics.

## Packaging and release gates

The x64 and ARM64 release paths publish the complete self-contained watchdog
runtime for the matching RID under `ComputerUseWatchdog/`. MSIX construction
fails when the nested executable is absent. Artifact Signing recursively signs
the watchdog's first-party binaries with the same RFC 3161-timestamped publisher
identity as the app. After signing, the x64 watchdog executes
`--verify-self-publisher`; the workflow fails if its runtime trust-provider path
does not accept the exact signed image.

## Local evidence

The following authoring-host checks pass at this change:

- Release IPC build, `net8.0` and `net10.0`: 0 warnings, 0 errors.
- Release watchdog build: 0 warnings, 0 errors.
- IPC tests: 22/22.
- Computer Use tests: 148 passed, 1 platform skip.
- Configuration tests: 58/58.
- Ops-script hardening, no-suppressions, and Windows tree-budget gates: pass.
- Self-contained `win-x64` publish: required executable/assembly/manifests present.

## Promotion boundary

Source composition promotes row 27 to SUB-DONE. Release promotion still requires the
exact-head Windows x64 and ARM64 build/test lanes plus the signed x64 runtime
publisher check. Physical certification must additionally prove authenticated
health, activate/clear persistence, process restart recovery, rejected wrong
publisher/unsigned peers, stale-heartbeat fail-closed behavior at the input
leaf, and panic-halt latency. Row 26 has a separate production-composition
receipt; its physical input and denial protocol remains an external host gate.
