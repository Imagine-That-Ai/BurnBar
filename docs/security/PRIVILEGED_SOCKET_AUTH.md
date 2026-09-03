# Privileged socket authentication (P0 + WS1)

> **Transport status (post-P0-6 / M-9):** the trusted per-user Unix-domain
> socket is the primary privileged-input transport. `PrivilegedInputXPCClient`
> tries that socket first and authenticates the server before writing any
> credential-bearing dispatch envelope. The retained launchd Mach fallback is
> limited to the privileged system service (`NSXPCConnection.Options.privileged`);
> the client must not fall back to unauthenticated user-session Mach lookup. The
> designated-requirement string below is the **M-9-fixed** form (the earlier
> requirement was too permissive; see "Designated requirement").

> **M-10 — remote-access agent signing + client-side server auth (2026-09-03):**
> the root `OpenBurnBarRemoteAccessAgent` is now installed **Developer-ID signed
> with hardened runtime and library validation** (`scripts/install-remote-access-agent.sh`
> fails closed without an identity; dev installs must opt in via
> `OPENBURNBAR_AGENT_ADHOC=1`), and its identifier
> (`com.openburnbar.remote-access-agent`) is an enumerated privileged peer.
> App clients (`RemoteAccessAgentClient`) authenticate the agent **server**
> (peer UID must be 0 + the first-party designated requirement) before writing
> any request — including `typeCredential`, which carries the macOS login
> password. A squatted or unsigned listener at
> `/var/run/openburnbar-remote-access-agent.sock` now receives zero bytes.
> Pinned by `RemoteAccessAgentClientTrustTests` (impostor listener) and the
> allowlist tests in `PrivilegedPeerAuthenticatorTests`.

## WS1 minimal TCB (2026-05-30)

| Component | Role | Entitlements |
|-----------|------|--------------|
| `OpenBurnBarPrivilegedInputExecution` | HID leaf behind the trusted per-user input socket | `hid.virtual.device` only |
| `OpenBurnBarVirtualHIDBridge` | Root bridge socket adapter → forwards to the console user's execution socket; privileged system Mach is retained only as a legacy fallback | None (no HID/network/keychain) |
| `OpenBurnBarRemoteAccessAgent` | Wake display, launch console-user workers, WS2 token stub | None (no HID/network/keychain) |

Dispatch uses `PrivilegedInputDispatchRequest` / `PrivilegedInputDispatchEnvelope`
(stable for WS2 capability tokens). The socket server authenticates both sides
of the privileged-input boundary before any credential-bearing envelope is
written, and the handler enforces the same fail-closed input policy (§"Virtual
HID `\"input\"` fail-closed policy").

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
- One of the **exact** first-party identifiers (there is no prefix operator — see the M-9 note below), including `com.openburnbar.remote-access-agent`
- Hardened Runtime + Library Validation (CodeDirectory flags, enforced programmatically)

> **M-9 fix:** an earlier requirement string was too permissive (it accepted
> any first-party identifier without binding the Team-ID OU and the identifier
> together), so a different team's Apple-signed binary could satisfy it, and the
> very first form used the literal `identifier "com.openburnbar.*"` which the
> requirement language exact-matches (no binary has that identifier). The
> current form binds **all** of anchor + leaf OU (Team ID) + an enumerated
> exact-identifier allowlist + Hardened-Runtime/Library-Validation, closing
> that gap. Re-run the red-team probe (below) after any change to
> `OpenBurnBarSigningIdentity`.

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
   Restart the launchd services / socket adapters so the running daemons match the new binaries.

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
