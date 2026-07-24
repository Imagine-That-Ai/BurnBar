# P-28 SmartHub installed proof

P-28 is certified only by a signed-candidate run in one of the seven supported
Linux environments. Source tests, fixture-mode UI, an isolated HTTP simulator,
or a copied Avahi transcript do not satisfy this proof.

## Live contract

`run-p28-native-smarthub-probes.mjs` requires the package-owned production
executables:

- `/usr/bin/openburnbar-cli`
- `/usr/libexec/openburnbar-daemon-launch`
- `/usr/bin/openburnbar-linux-desktop`

The runner requires one active installed daemon, one live SmartHub bridge, a
real D-Bus desktop session, Avahi, AT-SPI, and a native screenshot backend. It
uses only the product's fixed commands:

- `local-peer advertise-metadata --json`
- `local-peer browse --json --timeout 3`
- `devices discover smarthub --json`
- `devices iot smarthub status --json`

The discovered `_openburnbar-peer._tcp` identity, Linux platform, mDNS pairing,
transport, protocol version, daemon version, resolved endpoint, health response,
and `/api/display` control response must agree. Free-form shell or device input
is never accepted as product evidence.

## Native sequence

The installed desktop is driven through AT-SPI and captured in four distinct
states:

1. `discovered`: live Avahi discovery exposes the advertised peer.
2. `controlled`: bridge health and the actionable display control both pass.
3. `degraded`: the bridge is deliberately stopped; the UI clears healthy state
   and exposes `blocked_bridge_not_reachable` with recovery guidance.
4. `recovered`: the bridge resumes, the daemon and desktop restart, the same
   peer identity persists, and health/control pass again.

Every state has a distinct nonblank PNG and a fresh AT-SPI document bound to the
run marker, random nonce, desktop PID, selected operation, focused action, and
visible status. The runner restores the original desktop PID set, SmartHub
bridge PID set, and daemon service state. Cleanup failure remains fatal and is
reported alongside any primary probe failure.

## Evidence chain

The runner emits exactly 11 owner-only artifacts:

- `smarthub-marker.json`
- `smarthub-peer-manifest.json`
- `smarthub-native-transcript.json`
- `smarthub-{discovered,controlled,degraded,recovered}.png`
- `smarthub-{discovered,controlled,degraded,recovered}-atspi.json`

`materialize-p28-smarthub-session.mjs` rejects extra files, symlinks, mutable
paths, wrong ownership, wrong compositor, reused output, candidate substitution,
or changed installed-manifest bytes. It copies the evidence under
`docs/linux-port/evidence/product-parity-inputs/P-28/<environment>/`, verifies
the Ed25519 installed manifest and its root-owned CLI, daemon, launcher, and
desktop inventory, then emits `p28-installed-smarthub-session.json`.

`capture-p28-smarthub-proof.mjs` requires the checkout HEAD and selected
candidate identity to match that session. It emits one
`feature.smarthub-installed` proof plus the feature registration. The P-28
product validator revalidates the complete source session and all transitive
artifacts; it rejects missing or duplicate proof roles.

## Fail-closed mutations

Focused tests reject forged peer metadata, non-production discovery commands,
stale or substituted AT-SPI, screenshot replay, partial recovery, stale healthy
state, failed process restoration, substituted installed paths, mismatched
package inventory, candidate relabeling, duplicate ownership, symlinks, extra
raw artifacts, wrong compositor identity, and output replay.

## QA

For each supported environment:

1. Install the selected signed candidate and verify the installed manifest.
2. Start the real daemon and supported SmartHub bridge in the target desktop.
3. Run the native P-28 producer with an empty owner-only HOME, support, and raw
   evidence directory.
4. Materialize and capture the proof using the same candidate run ID, artifact
   digest, version, HEAD, manifest digest, and signature digest.
5. Run `node --test scripts/linux-port/p28-native-smarthub-probes.test.mjs
   scripts/linux-port/p28-smarthub-proof.test.mjs
   scripts/linux-port/ownership-tests/P-28.test.mjs`.
6. Confirm the strict product workflow accepts all seven environment proofs;
   no single local run alone certifies parity.
