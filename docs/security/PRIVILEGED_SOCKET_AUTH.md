# Privileged socket authentication (P0 + WS1)

## WS1 minimal TCB (2026-05-30)

| Component | Role | Entitlements |
|-----------|------|--------------|
| `OpenBurnBarPrivilegedInputExecution` | HID leaf (XPC Mach service `com.openburnbar.privileged-input-execution`) | `hid.virtual.device` only |
| `OpenBurnBarVirtualHIDBridge` | Legacy Unix socket adapter → forwards to execution over XPC | None (no HID/network/keychain) |
| `OpenBurnBarRemoteAccessAgent` | Wake display, launch console-user workers, WS2 token stub | None (no HID/network/keychain) |

Clients prefer **XPC** (`PrivilegedInputXPCClient` in `OpenBurnBarComputerUseCore`); the socket path remains until migration completes. Dispatch uses `PrivilegedInputDispatchRequest` / `PrivilegedInputDispatchEnvelope` (stable for WS2 capability tokens).

All three privileged helpers are built with **Hardened Runtime** enabled in `project.yml`.

---

## P0 peer authentication

OpenBurnBar privileged UNIX-domain sockets (`openburnbar-virtual-hid.sock`, `openburnbar-remote-access-agent.sock`) accept connections only from:

1. The interactive **console user** (cheap `getpeereid` gate), and
2. A **first-party code signature** validated via the peer's audit token (`LOCAL_PEERTOKEN` → `SecCode` + designated requirement).

## Designated requirement

Canonical Team ID and requirement string live in `OpenBurnBarSigningIdentity` (`OpenBurnBarRemoteAccessAgentCore`). The requirement enforces:

- `anchor apple generic`
- `certificate leaf[subject.OU] = "<TEAM_ID>"`
- `identifier "com.openburnbar.*"`
- Hardened Runtime + Library Validation

## Virtual HID `"input"` fail-closed policy

Until WS2 capability tokens ship, `VirtualHIDBridgeInputPolicy` allows only Remote Unlock–certified action kinds (`click`, `pointer_move`, certified keys). Arbitrary `type`, `scroll`, and general `key`/`shortcut` payloads are rejected and audited.

## Audit events

| Event | When |
|-------|------|
| `privileged_socket_peer_accepted` | Peer passed UID + code-sign checks |
| `privileged_socket_peer_rejected` | Peer failed either check |
| `privileged_bridge_input_accepted` | `"input"` passed policy and executed |
| `privileged_bridge_input_rejected` | `"input"` failed policy |

Events are emitted as JSON lines on stderr (`privileged_socket_audit …`).

## Red-team regression

Build `OpenBurnBarPrivilegedSocketRedTeamProbe` and run against a live socket. **Exit 1** means the server rejected the probe (expected post-P0). **Exit 0** means the vulnerability is still present.

### Live drill (operator runbook)

1. Rebuild and install the privileged helpers from a P0+ tree (Virtual HID bridge + Remote Access Agent + input execution leaf):
   ```bash
   cd /path/to/BurnBar
   xcodebuild -scheme OpenBurnBarPrivilegedInputExecution -destination 'platform=macOS' build
   xcodebuild -scheme OpenBurnBarVirtualHIDBridge -destination 'platform=macOS' build
   xcodebuild -scheme OpenBurnBarRemoteAccessAgent -destination 'platform=macOS' build
   ```
   Restart the launchd Mach services / socket adapters so the running daemons match the new binaries.

2. Run the opt-in integration probe against the live sockets:
   ```bash
   export RUN_PRIVILEGED_SOCKET_REDTEAM=1
   cd OpenBurnBarDaemon
   swift test --filter PrivilegedSocketRedTeamIntegrationTests
   ```

3. **Pass criteria:** the XCTest suite skips unless `RUN_PRIVILEGED_SOCKET_REDTEAM=1` is set; when set, unsigned / wrong-signature peers must be rejected (probe exits non-zero / test passes). Re-run after every privileged-helper change before shipping.

See `OpenBurnBarDaemon/Tests/OpenBurnBarRemoteAccessAgentCoreTests/PrivilegedSocketRedTeamIntegrationTests.swift`.

## Leaf kill switch

`PrivilegedInputKillSwitch` (`/var/run/openburnbar-privileged-input-kill`) is set on app panic and checked on every Virtual HID dispatch.

An always-on **watchdog LaunchDaemon** (`com.openburnbar.privileged-input-killswitch-watchdog`) can activate the same flag when the app cannot — install via [`scripts/install-privileged-input-killswitch-watchdog.sh`](../../scripts/install-privileged-input-killswitch-watchdog.sh). See [`PRIVILEGED_INPUT_THREAT_MODEL.md`](PRIVILEGED_INPUT_THREAT_MODEL.md).
