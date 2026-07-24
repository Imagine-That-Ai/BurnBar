# P-16 Cloud And Trusted Devices Installed Proof

P-16 certification joins two deliberately separate authorities: the signed installed Linux candidate owns its daemon-backed account state, while a physical trusted iPad owns Linux App Check device listing, approval, and revocation. Linux never receives the mobile action nonce, signed action proof, App Check token, Firebase token, refresh token, or private installation key.

## Required lifecycle

The installed session must prove:

- Package-owned `/usr/bin/openburnbar-linux-desktop` and `/usr/bin/openburnbar-daemon` match the signed release candidate.
- Pending approval exposes only hashes of the stable Linux device ID and public safety fingerprint.
- A physical, non-Simulator iPad running the signed `com.openburnbar.app` host lists the pending device through `listLinuxAppCheckDevices`.
- The iPad approves through `approveLinuxAppCheckDevice` using a fresh nonce-bound signed action proof, lists the approved result, then revokes through `revokeLinuxAppCheckDevice` with a second signed action proof and lists the revoked result.
- Linux observes pending, active/cloud-ready, rejected/unavailable, recovered, and restart-persistent states through the installed product boundary.
- A controlled daemon outage produces an explicit error without optimistic success, recovery restores the last authoritative state, and desktop restart preserves it.
- The created cloud device is revoked, no mutation remains pending, the daemon/service/process state is restored, and evidence contains no authentication material.

Five distinct screenshots and AT-SPI snapshots bind Pending, Approved, Revoked, Degraded, and Recovered states to the Account route. A mobile receipt outside the bounded Linux session, a Simulator receipt, missing App Check attestation, wrong callable order, reused nonce proof, raw device identifier, or incomplete cleanup fails certification.

## Physical-iPad coordination

P-16 is a live two-party protocol, not a pre-generated mobile fixture. Point the
Linux probe and macOS iPad producer at the same empty, owner-only UTM shared
directory. The Linux probe requires `--coordination-dir`; `--mobile-receipt` is
optional for compatibility and, when supplied, must be exactly
`<coordination-dir>/p16-mobile-receipt.json`.

1. Linux rotates its isolated installation identity, proves the pending state,
   and atomically publishes `p16-trust-request.json`. The request binds target
   HEAD, candidate run and digest, marker, challenge, and hashed Linux identity.
2. `capture-p16-physical-ipad-trust-cycle.sh` validates those expected bindings,
   selects a connected physical iPad, and runs only the approval XCTest phase.
3. Linux observes approved/cloud-ready, daemon degradation and recovery, and
   restart persistence before publishing `p16-revoke-ready.json`.
4. The wrapper validates that acknowledgement, runs the revocation phase, and
   atomically publishes `p16-mobile-receipt.json`. Linux then observes revoked
   state and consumes the receipt before closing its transcript.

Run the macOS side while the Linux probe is waiting:

```bash
scripts/linux-port/capture-p16-physical-ipad-trust-cycle.sh \
  --coordination-dir "$OPENBURNBAR_P16_MACOS_COORDINATION_ROOT" \
  --target-head "$TARGET_HEAD" \
  --candidate-run-id "$CANDIDATE_RUN_ID" \
  --candidate-artifact-digest "$CANDIDATE_ARTIFACT_DIGEST"
```

The wrapper disables automatic XCTest retries because replaying a high-risk
approval or revocation after a partial failure would invalidate the proof. A
manual invocation retains its named scratch root for diagnosis; the registered
workflow supplies a runner-temporary scratch root and removes it after capture.
The receipt contains hashes of device identifiers, action nonces, and signed
proofs only; App Check/auth tokens, signatures, private keys, and raw Linux
identifiers never cross the evidence boundary.

The registered GitHub workflow runs the macOS/iPad producer and Linux consumer
concurrently. Repository variables
`OPENBURNBAR_P16_MACOS_COORDINATION_ROOT` and
`OPENBURNBAR_P16_LINUX_COORDINATION_ROOT` must name the macOS and guest paths to
the same owner-only (`0700`) UTM shared directory. The workflow creates a unique
`<run>-<attempt>-<environment>` child and the Linux job removes that child after
the bound receipt has been consumed. The macOS runner must be self-hosted,
Apple-silicon, signed into the mobile test account, and have the physical iPad
paired and available.

## Honest boundary

This proof does not claim Linux can approve itself. It proves only the account
and trusted-device lifecycle. It does not relabel backup, sync completeness,
conflict resolution, or remote access as complete; those require their own
daemon contracts and installed evidence.

P-16 is registered in the shared proof registry and workflow. That registration
proves ownership and makes the live trust-cycle producer executable; it does not
turn the unsupported backup, sync, conflict, or remote-access sub-capabilities
into passing evidence. Strict parity remains blocked until those contracts and
the required signed-candidate environment receipts exist.
