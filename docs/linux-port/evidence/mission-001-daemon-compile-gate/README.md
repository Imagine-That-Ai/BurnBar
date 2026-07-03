# Linux Daemon Compile-Gate Evidence

Assignment: mission-001 daemon/CLI Linux compile gate after residual core hardening.

Verified commands:

- `docker run --rm -v /private/tmp/openburnbar-linux-mission-001:/workspace -w /workspace/OpenBurnBarDaemon openburnbar-linux-toolchain:mission-001 swift build --build-path /workspace/OpenBurnBarDaemon/.build-linux-daemon-compile-gate --target OpenBurnBarDaemon --target OpenBurnBarCLI --target OpenBurnBarDaemonExecutable` exited `0`.
- `docker run --rm -v /private/tmp/openburnbar-linux-mission-001:/workspace -w /workspace/OpenBurnBarDaemon openburnbar-linux-toolchain:mission-001 swift build --build-path /workspace/OpenBurnBarDaemon/.build-linux-daemon-compile-gate-evidence --target OpenBurnBarDaemon --target OpenBurnBarCLI --target OpenBurnBarDaemonExecutable` exited `0`; full output is in `swift-build.txt`.
- `rg -n "DaemonEnvelope|DaemonTransport|UnixSocketTransport|NSXPC" OpenBurnBarDaemon/Sources/OpenBurnBarDaemon OpenBurnBarDaemon/Sources/OpenBurnBarDaemonExecutable OpenBurnBarDaemon/Sources/OpenBurnBarCLI` produced no matches; see `forbidden-rpc-invention-scan.txt`.
- `rg -n "BurnBarRPC|AF_UNIX|sun_path|SOCK_STREAM|MSG_NOSIGNAL|peerPID|linuxPeerCredential" OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarDaemonPeerAuthenticator.swift` recorded the preserved AF_UNIX RPC path; see `burnbarrpc-af-unix-scan.txt`.

Key observations:

- `swift-build.txt` ends with `Build of target: 'OpenBurnBarDaemonExecutable' complete!`, proving the Linux target trio compiled together after the daemon/CLI boundary fixes.
- The compile still emits pre-existing warnings from shared core and daemon files, but no errors remain in the Linux daemon lane.
- No alternate daemon transport names were introduced; the retained daemon transport is still the existing BurnBarRPC AF_UNIX socket flow.

Supporting notes:

- `target-map.md` lists every Linux exclusion or stubbed replacement in `OpenBurnBarDaemon/Package.swift` and the resulting fail-closed or narrowed behavior.
