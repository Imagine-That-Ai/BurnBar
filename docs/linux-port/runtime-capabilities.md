# Linux runtime capability contract

The Linux desktop evaluates platform and product prerequisites before it mounts
workflow controls. This is a runtime safety contract, not a parity claim. A
capability can be present while a deeper feature-specific probe still reports a
recoverable error, and the release ledger remains the authority for promotion.

## Canonical inputs

- `packaging/linux/runtime-capability-catalog.json` owns capability IDs,
  domains, route assignments, native evaluators, unavailable reasons, and
  supported substitutes.
- `schemas/linux-runtime-capability-manifest.schema.json` owns the serialized
  manifest shape.
- `apps/linux-desktop/src-tauri/src/lib.rs` embeds the catalog at compile time,
  performs native probes, and returns the `runtime_capabilities` command.
- `apps/linux-desktop/src/runtimeCapabilities.ts` validates native data before
  the renderer may use it.
- `apps/linux-desktop/src/routes.ts` assigns exactly one required capability to
  every route.

Update availability and update installation are intentionally separate
capabilities. `updates.check` permits the Updates route to mount and invoke the
native signed-feed verifier. `updates.install` remains unavailable because
Linux package ownership belongs to apt, dnf, Flatpak, or the AppImage workflow;
the app shows the native command and rollback guidance instead of mutating
package-managed files.

The contract test rejects duplicate or unknown IDs, missing route mappings,
unknown evaluators, schema drift, and removal of either the native or renderer
boundary:

```bash
node --test scripts/linux-port/runtime-capability-contract.test.mjs
```

## States

| State | Meaning | Renderer behavior |
|---|---|---|
| `available` | The native prerequisite passed. | Mount the route surface. |
| `degraded` | A usable Linux-native substitute exists with a named limit. | Show the limitation, then mount the surface. |
| `unavailable` | The prerequisite is absent in this session or build. | Do not mount workflow controls; show reason and repair path. |
| `blocked` | Policy or release posture explicitly forbids the workflow. | Do not mount workflow controls; show reason and repair path. |

Browser preview mode has no native bridge and remains usable for development.
The packaged Tauri shell is fail closed: before the manifest arrives, when
validation fails, or when a route entry is missing, the underlying surface is
not mounted.

## Native evaluators

| Evaluator | Evidence |
|---|---|
| `always` | Compiled shell contract. |
| `daemon` | Authenticated Unix-socket `daemon.health` result. |
| `gateway` | Daemon health plus authenticated loopback gateway enabled. |
| `trusted-cli` | Root-owned, non-writable CLI at a fixed package path. |
| `secret-service` | Session D-Bus plus trusted `secret-tool`. |
| `kwallet` | Session D-Bus plus trusted `kwallet-query`. |
| `portal` | Session D-Bus is present; individual portal grants remain user mediated. |
| `tray` | Tauri tray initialization succeeded. |
| `x11-overlay` | X11 session supports the constrained overlay tier; other sessions degrade. |
| `unavailable` | No safe Linux implementation is shipped yet. |

The `always` evaluator for `updates.check` means the native verifier is compiled
and callable, not that a public release feed is valid or reachable. Feed
signature, schema, architecture, channel, and version checks can still return a
typed fail-closed result.

Daemon-backed evaluators establish the shared runtime prerequisite. Individual
surfaces must continue to probe their feature RPC and display typed errors;
daemon health alone must not be treated as proof of end-to-end feature parity.

## Browser Computer Use package boundary

Linux packages own the canonical bridge at
`/usr/lib/openburnbar/playwright/openburnbar-playwright-bridge.js`. The daemon
launcher exports that exact package path for deb/rpm and the equivalent
`$APPDIR` path for AppImage. The installed signed manifest measures the deb/rpm
bridge bytes; AppImage embedding verifies the same resource before rebuilding
the image.

The package does not claim to bundle Playwright or Chromium. Native deb/rpm/AUR
metadata requires Node 18 or newer and npm; AppImage treats both as external.
All formats require an exactly pinned, root-provisioned `playwright@1.49.1` at
`/usr/lib/node_modules/playwright`, its `playwright-core` dependency at
`/usr/lib/node_modules/playwright-core`, plus Chromium under
`/usr/lib/openburnbar/playwright-browsers`. Packaged launches discard ambient
`NODE_OPTIONS` and `NODE_PATH`; the bridge recursively requires uid-0 ownership
and rejects every group/world-writable entry or escaping symlink before loading
Playwright or launching Chromium. No Computer Use action installs or upgrades
these dependencies. The read-only package probe verifies that trust boundary,
the exact Playwright version, Chromium executable access, and a real headless
Chromium launch:

```bash
/usr/lib/openburnbar/playwright/openburnbar-browser-runtime-probe
```

For an extracted AppImage, run the same command below `$APPDIR/usr/lib/...`
with `APPDIR` set. A nonzero exit or JSON `ready: false` blocks Browser Computer
Use. A green probe proves prerequisites only; it does not prove signed phone
authority, approvals, desktop integration, restart recovery, accessibility, or
the seven-environment installed parity matrix.

The packaged daemon launcher uses an absolute shell, a fixed executable search
path, an exact package-owned Swift library path, and no user-writable generic
environment file. Both systemd and the launcher remove shell startup hooks,
dynamic-loader injection variables, and Node injection variables before daemon
startup; the daemon then gives the Playwright child a separate allowlisted
environment. Administrator overrides belong in a reviewed systemd drop-in, not
`~/.config/openburnbar/daemon.env`.

## Browser Computer Use owner authorization

Browser session start requires two independent authorities: the exact signed
grant from the pinned paired phone and a fresh Linux desktop-owner decision.
The daemon binds the latter to the authenticated Tauri socket peer PID, UID,
process start time, executable device, and inode; it repeats that identity check
after the prompt before consuming the phone grant. The Computer Use path accepts
only the dedicated polkit action and deliberately has no PAM fallback.

Deb, RPM, and the package-managed AUR recipe install
`com.openburnbar.computer-use.policy` at
`/usr/share/polkit-1/actions/` with mode `0644` and require polkit. The policy
uses fresh `auth_self`, not cached `auth_self_keep`. Standalone AppImage and
Flatpak payloads cannot install a host policy and must report authority
unavailable unless a trusted system package already installed the exact policy.
No package or runtime flow may self-install or modify that privileged asset.

A green owner prompt proves only local authorization. It cannot replace the
phone signature, elevate trust, broaden capabilities, or authorize later
actions. The shipping Linux iroh backend, paired-controller registry, trusted
QUIC-transport-to-signing-authority mapping, publisher, and pairing metadata
resolver remain prerequisites. Android challenge reception and installed
real-phone evidence are still required.

The desktop's idle state also calls
`daemon.computer_use.session_grant.readiness`. It enables session start only
after the daemon confirms an operational publisher/validator broker, metadata
resolver, readiness provider, and trusted paired-controller path. A missing or
malformed readiness response is unavailable, never optimistic.

## Change procedure

1. Add or change the catalog entry, including an actionable reason and
   substitute for every evaluator that can be unavailable.
2. Add the ID to the renderer union and map every affected route.
3. Implement the native evaluator without ambient `PATH`, renderer network
   access, or secret exposure.
4. Add positive, degraded, unavailable, and malformed-manifest tests.
5. Run the contract, TypeScript, Rust, desktop unit, and production bundle
   checks.
6. Update the parity ledger only after current-HEAD evidence exists; do not
   infer parity from an `available` runtime state.

## QA verification

For each supported desktop environment:

1. Launch the packaged app with the daemon healthy and confirm all
   daemon-required routes mount.
2. Stop the daemon and confirm those routes show the capability boundary with
   no workflow buttons or forms in the accessibility tree.
3. Remove or mask each optional native dependency and confirm the matching
   reason and substitute.
4. Run on X11 and Wayland and confirm the pet reports `available` and
   `degraded`, respectively.
5. Corrupt a development manifest response and confirm the packaged renderer
   fails closed without crashing.
6. Navigate from an unavailable route to Support using keyboard only and
   confirm focus, screen-reader announcement, and 200 percent zoom behavior.
7. Verify the production bundle contains no fixture data, bearer token, or
   direct loopback networking marker.
8. Serve current, newer, offline, malformed, unsigned, tampered, replayed,
   downgrade, wrong-architecture, and wrong-channel update fixtures to a debug
   build; confirm only a signed newer compatible release enables the first-party
   download action.

Required commands:

```bash
node --test scripts/linux-port/runtime-capability-contract.test.mjs
node scripts/linux-port/verify-linux-workflow-wiring.mjs
apps/linux-desktop/node_modules/.bin/tsc --noEmit -p apps/linux-desktop/tsconfig.json
npm test --prefix apps/linux-desktop
npm run build --prefix apps/linux-desktop
cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --locked
```
