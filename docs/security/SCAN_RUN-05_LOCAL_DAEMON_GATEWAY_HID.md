# Security Scan Report: run-05-local-daemon-gateway-hid

**Date:** 2026-06-14  
**Status:** COMPLETE  
**Lens:** macOS daemon, UNIX socket auth, peer code-sign checks, local HTTP gateway, privileged input/HID bridge, same-user process risks  
**Threat model mappings:** TM-001 (privileged daemon IPC / same-user local attacker), TM-008 (HTTP gateway loopback exposure / network attacker)

---

## Scope

### Primary targets inspected (full source read)

| File | Lines |
|------|-------|
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift` | 644 |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarDaemonPeerAuthenticator.swift` | 114 |
| `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarHTTPGatewayServer.swift` | 3060 |
| `OpenBurnBarDaemon/Sources/OpenBurnBarRemoteAccessAgentCore/PrivilegedInputExecutionSocketServer.swift` | 291 |

### Supporting files inspected (full source read)

- `OpenBurnBarDaemonMain.swift` (production wiring point)
- `OpenBurnBarDaemonConfiguration.swift` (validation logic, gateway config)
- `PrivilegedPeerAuthenticator.swift` (privileged socket peer auth)
- `PrivilegedSocketTrust.swift` (shared trust primitives, DR string)
- `PrivilegedInputDispatchHandler.swift` (HID handler, capability gate)
- `VirtualHIDBridgeCapabilityGate.swift` (input action policy + token gate)
- `BurnBarRateLimiter.swift` (token bucket implementation)
- `ConstantTimeCompare.swift` (timing-safe token comparison)
- `docs/security/BurnBar-threat-model.md` (TM-001, TM-008, boundary table, spoofing table)

---

## Product Security Position

OpenBurnBar is not zero-knowledge, not universal E2EE. The cloud sees account, entitlement, routing, metadata, index, audit, and push data. Endpoints see plaintext after local decryption. The daemon and gateway are local-first surfaces guarded by code-signing and UNIX-socket permissions, not by network encryption.

---

## Attack Surface Classification

### Same-User Local Attacker (Primary Threat per TM-001)

The attacker runs as the same UID as the daemon. They can:

- Connect to any UNIX socket the daemon owns (0600 perms limit other users, not same-user).
- Read the socket path from process args, environment, or `lsof`.
- Potentially read environment variables if they can inspect the daemon's launchd plist or process environment (depends on macOS SIP / launchd protections).
- Not forge a first-party code signature without the Team ID private key (4Y367DF25B).

**Primary control:** RR-3 audit-token code-signature gate (`BurnBarDaemonPeerAuthenticator`, `PrivilegedPeerAuthenticator`, `OpenBurnBarPrivilegedTrust`), enforced by default in production via `OpenBurnBarDaemonMain.makePeerAuthenticator()`.

### Network Attacker (Secondary, Gateway Only per TM-008)

Only the HTTP gateway (`BurnBarHTTPGatewayServer`) binds to a TCP port. Default is `127.0.0.1:8317`. A network attacker can reach the gateway only if the user misconfigures the bind address to a routable interface.

**Primary controls:** Host validation rejects `0.0.0.0`/`::`; non-loopback binds require an auth token; constant-time token comparison prevents timing oracles.

---

## Verified Controls (Threat Model Alignment)

| TM Ref | Control | Source Evidence | Verdict |
|--------|---------|----------------|---------|
| TM-001 | UNIX socket peer auth: audit token + first-party code-sig DR | `BurnBarDaemonPeerAuthenticator.swift:83-101`, `PrivilegedSocketTrust.swift:112-145`, `OpenBurnBarDaemonMain.swift:83-102` | **VERIFIED** - enforced by default, fail-closed |
| TM-001 | Socket path permissions 0600 | `OpenBurnBarDaemonServer.swift:225` (`S_IRUSR | S_IWUSR`), `PrivilegedInputExecutionSocketServer.swift:177` (umask 0o077 + chmod 0600) | **VERIFIED** |
| TM-001 | Socket directory 0700, parent ownership validated | `OpenBurnBarDaemonServer.swift:193` (`0o700`), `PrivilegedInputExecutionSocketServer.swift:87-122` (validateSocketDirectory checks dir 0700 + parent not world-writable) | **VERIFIED** - structural defense against socket squatting |
| TM-001 | HID capability token: signed, nonce-replay-protected, action-scoped | `VirtualHIDBridgeCapabilityGate.swift:58-89`, `CapabilityTokenVerifier.swift`, `PrivilegedInputDispatchHandler.swift:34-50` | **VERIFIED** - `typeCredential` and `input` both gated; `health` is the only ungated op |
| TM-001 | Kill switch check before HID dispatch | `PrivilegedInputDispatchHandler.swift:29` (`PrivilegedInputKillSwitch.assertNotActive()`) | **VERIFIED** |
| TM-001 | Forwarded audit token validation (bridge to leaf) | `PrivilegedInputDispatchHandler.swift:26-28` | **VERIFIED** |
| TM-008 | Gateway wildcard bind (0.0.0.0/::) rejected | `OpenBurnBarDaemonConfiguration.swift:148-150` | **VERIFIED** |
| TM-008 | Gateway auth token required unless allowUnauthenticatedLoopback opted in | `OpenBurnBarDaemonConfiguration.swift:155-163` | **VERIFIED** - fail-closed |
| TM-008 | Constant-time token comparison | `ConstantTimeCompare.swift:11-24` (`@inline(never)`, XOR-accumulate, length-folded) | **VERIFIED** |
| TM-008 | Request size limits | `OpenBurnBarDaemonServer.swift:6` (64KB socket), `OpenBurnBarHTTPGatewayServer.swift:28-29` (16KB header, 64MB body), `PrivilegedInputExecutionSocketServer.swift:263` (16KB HID) | **VERIFIED** |
| TM-001 | Privileged input connection slot limiting (DoS mitigation) | `PrivilegedInputExecutionSocketServer.swift:37` (`DispatchSemaphore(value: max(1, maximumConcurrentConnections))`, default 4) | **VERIFIED** |

---

## Validated Findings

### LD-01: Peer code-sig enforcement can be disabled via environment variable [Medium]

**Threat model:** TM-001 (same-user local attacker)  
**Attacker class:** Same-user local

**Evidence:**

- `OpenBurnBarDaemonMain.swift:84-101`: `makePeerAuthenticator()` checks `OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1` or `BURNBAR_DAEMON_DISABLE_PEER_CODESIG=1` and returns `.disabled`.
- When disabled, any same-user process that learns the bearer token can issue RPCs including provider credential writes, computer-use dispatch, and mission control operations.

**Exploitability:** A same-user attacker who can read the daemon's environment (e.g., via `ps eww`, launchd plist inspection) can determine if the flag is set. If an operator sets this flag for development and forgets to remove it, the daemon runs without its primary access control. The flag is logged as a warning (`rpc_peer_code_signature_enforcement_disabled`) but there is no hard gate preventing it in a production-signed binary.

**Mitigation status:** The flag is documented as an unsigned-developer-build escape hatch. The bearer token (`socketAuthToken`) remains as defense-in-depth, and `validate()` requires it to be non-nil. However, a same-user process can read the token from the socket path's parent directory metadata or the app's process arguments.

**Recommendation:** Gate the disable flag behind a `#if DEBUG` compile condition so a release-signed daemon binary cannot have peer auth disabled at runtime regardless of environment. Alternatively, require the daemon binary itself to be unsigned (detect via `SecCodeCopySelf` check) before honoring the flag.

---

### LD-02: Gateway allow-unauthenticated-loopback opt-out [Medium]

**Threat model:** TM-008 (loopback exposure)  
**Attacker class:** Same-user local (any process on the host)

**Evidence:**

- `OpenBurnBarDaemonConfiguration.swift:155-163`: If `authToken` is nil and the host is loopback, the gateway starts only if `allowUnauthenticatedLoopback == true`. This is the fail-closed path.
- `OpenBurnBarDaemonMain.swift:165-166`: The flag is set via `OPENBURNBAR_GATEWAY_ALLOW_UNAUTHENTICATED_LOOPBACK=1` or `--gateway-allow-unauthenticated-loopback`.

**Exploitability:** When this flag is set, any same-host process can call `/v1/chat/completions`, `/v1/messages`, etc. and spend the user's provider credits (API keys stored in the daemon's config store). The gateway routes to the provider router, which has access to all configured credentials. This is a financial / quota abuse vector, not a data exfiltration vector.

**Mitigation status:** Fail-closed by default. The opt-in requires an explicit environment variable or CLI flag. This is documented as unsafe.

**Recommendation:** The current design is acceptable as an explicit opt-in. Consider adding a startup log warning at `notice` level and optionally a periodic reminder in the gateway health/metrics endpoint that auth is disabled.

---

### LD-03: Gateway host validation does not block non-loopback LAN or IPv6 link-local addresses [Medium]

**Threat model:** TM-008 (network attacker)  
**Attacker class:** Network attacker (on LAN or link-local)

**Evidence:**

- `OpenBurnBarDaemonConfiguration.swift:142-160`: The `validationError` property rejects empty host, ports outside 1-65535, `0.0.0.0`, `::`, and invalid hostnames. It requires an auth token for non-loopback binds. But it does not reject a specific routable LAN address like `192.168.1.100` or an IPv6 link-local address like `fe80::1`.
- `isValidHost` (line 167) accepts any valid IPv4 address or `localhost`/`::1`.

**Exploitability:** If a user explicitly sets `--gateway-host 192.168.1.100` (or any routable IP), the gateway binds to that interface. If they also provide an auth token, the token is the only protection. If the token is weak or leaked (e.g., visible in process args via `ps`), a network attacker on the LAN can reach the gateway and spend provider credits. The auth token is the sole barrier at that point.

**Skeptical challenge:** Is this actually a vulnerability, or is it intentional that users can bind to a LAN address for legitimate use cases? The code requires a token for non-loopback binds, which is the correct control. The risk is in the token being passed via CLI args, which are visible to same-user processes via `ps`.

**Verdict:** Validated as a medium-severity configuration hardening issue, not a code defect. The control (token required for non-loopback) is correct. The residual risk is token exposure via process args.

**Recommendation:** Prefer reading the gateway auth token from a file or Keychain rather than CLI args/env vars. Consider adding a startup warning when the gateway binds to a non-loopback address.

---

### LD-04: PID-based rate limiting is susceptible to PID reuse [Low]

**Threat model:** TM-001 (same-user local attacker)  
**Attacker class:** Same-user local

**Evidence:**

- `OpenBurnBarDaemonServer.swift:401-403`: Rate limiting uses `peerPID` (from `LOCAL_PEERPID`) as the client key. If PID lookup fails, the key is `"unknown"`.
- `BurnBarRateLimiter.swift:34-52`: Token bucket is keyed by client key string.

**Exploitability:** macOS reuses PIDs aggressively. A same-user attacker who can spawn and kill processes rapidly could get assigned the PID of a recently-terminated first-party client, inheriting its remaining rate-limit budget. However, this requires precise timing and the RR-3 code-signature gate still blocks the attacker from passing peer auth, so the rate limiter is not the primary access control. The `"unknown"` fallback bucket is shared by all peers where PID lookup fails, which is a minor concern.

**Verdict:** Low severity. Rate limiting is a resource-protection control, not an access control. The code-sig gate is the real barrier.

---

### LD-05: Bearer token is defense-in-depth, not the primary gate [Low / Informational]

**Threat model:** TM-001

**Evidence:**

- `OpenBurnBarDaemonServer.swift:365-379`: The socket auth token is checked after the peer authenticator (line 581-595). The peer authenticator runs first in `handleClientConnection` (line 577-595). If peer auth passes (valid first-party signature), the token is a secondary check.
- `BurnBarDaemonConfiguration.swift:229-234`: `validate()` requires a non-nil socket auth token before the daemon starts.

**Verdict:** Correct layered design. The token exists as defense-in-depth for the scenario where the code-sig gate is disabled (LD-01). No vulnerability, just documenting the trust chain.

---

### LD-06: Gateway anonymous rate-limit bucket shared by unauthenticated clients [Low]

**Threat model:** TM-008  
**Attacker class:** Same-user local

**Evidence:**

- `OpenBurnBarHTTPGatewayServer.swift:2411-2415`: `rateLimitClientKey(for:)` returns `"anonymous"` when no token is presented. All unauthenticated requests share a single rate-limit bucket.

**Exploitability:** When `allowUnauthenticatedLoopback` is enabled, multiple processes hitting the gateway share one bucket. A noisy process can exhaust the bucket for all others. This is a fairness issue, not a security bypass. The token-based key (`"token:<sha256>"`) correctly separates authenticated clients.

**Verdict:** Low severity. Only relevant when the unauthenticated loopback opt-in is active.

---

### LD-07: HID health operation returns ok=true unconditionally [Informational]

**Threat model:** TM-001

**Evidence:**

- `PrivilegedInputDispatchHandler.swift:31-33`: The `"health"` operation returns `PrivilegedInputDispatchResponse(ok: true)` without checking any state. The kill switch check (`PrivilegedInputKillSwitch.assertNotActive()`) runs on line 29 before the switch, so a health check will throw if the kill switch is active. But the `ok: true` response is hardcoded and does not reflect actual HID device availability or session state.

**Exploitability:** None. This is an information disclosure at most (confirming the socket is alive), which is already gated by peer auth. No bypass.

**Verdict:** Informational only. No action needed.

---

## Deduplication and Cross-Reference

Cross-checked against existing remediation docs in `docs/security/`:

- **LD-01** is related to RR-3 (the peer auth remediation). The escape hatch is the known residual risk from RR-3's design for unsigned developer builds. No prior finding explicitly flags the env-var-as-runtime-flag concern.
- **LD-02** is the documented design of `allowUnauthenticatedLoopback`. Not a new finding but confirmed as correctly implemented (fail-closed).
- **LD-03** is not covered by any prior finding. The gateway host validation stops at wildcard rejection. New observation.
- **LD-04 through LD-07** are defense-in-depth observations not covered by prior findings.

---

## Claims Defensible from Source Evidence

1. The RR-3 peer code-signature gate is enforced by default in production (`OpenBurnBarDaemonMain.swift:97-101`). A release-signed daemon binary refuses any peer that does not satisfy the first-party designated requirement (Team ID `4Y367DF25B` + exact bundle ID + hardened runtime + library validation).
2. The privileged input execution socket validates socket directory ownership and permissions before binding (`PrivilegedInputExecutionSocketServer.swift:87-122`), structurally preventing socket-path squatting.
3. The HID `typeCredential` and `input` operations require a valid capability token (signed, nonce-replay-protected, action-scoped) verified by `VirtualHIDBridgeCapabilityGate`.
4. The HTTP gateway rejects wildcard bind addresses (`0.0.0.0`, `::`) and requires an auth token for all binds unless `allowUnauthenticatedLoopback` is explicitly opted in.
5. Token comparisons on both the socket and gateway use a constant-time comparison function that does not short-circuit.

## Claims Not Defensible from Repo Evidence Alone

1. Whether the deployed production daemon binary actually has peer auth enabled (depends on whether `OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG` is set in the launchd plist on production machines).
2. Whether the gateway auth token is strong in production (it comes from env vars / CLI args visible to same-user processes).
3. Whether the privilege input kill switch is active and tested against a live HID device.
4. Whether Firebase App Check enforcement, Remote Config, and IAM/KMS bindings match the repo-described design on the live project.

---

## Severity Summary

| Severity | Count | Findings |
|----------|-------|----------|
| Critical | 0 | -- |
| Medium | 3 | LD-01, LD-02, LD-03 |
| Low | 3 | LD-04, LD-05, LD-06 |
| Informational | 1 | LD-07 |

## Top Recommendations

1. **LD-01:** Compile-time gate `OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG` behind `#if DEBUG` so release binaries cannot disable peer auth at runtime.
2. **LD-03:** Prefer reading the gateway auth token from Keychain rather than CLI args/env vars. Add a startup warning for non-loopback binds.
3. **LD-02:** Acceptable as-is (explicit opt-in, fail-closed by default). Add startup notice logging for operational visibility.
