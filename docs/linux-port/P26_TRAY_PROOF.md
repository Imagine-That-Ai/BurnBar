# P-26 Installed Tray and Native Shell Proof

P-26 closes only when the exact signed Linux candidate proves its native tray
and background-shell lifecycle in a real supported desktop session. Rust unit
tests, source inspection, fixture UI, and an unbound StatusNotifier screenshot
are not product evidence.

## Required lifecycle

`scripts/linux-port/run-p26-native-tray-probes.mjs` runs the installed
`/usr/bin/openburnbar-linux-desktop` and packaged daemon against an isolated,
owner-only home, support directory, Unix socket, auth token, and index database.
It must prove, in order:

1. `/etc/xdg/autostart/openburnbar.desktop` is owned by the canonical
   `openburnbar` package according to dpkg, RPM, or pacman and executes the
   canonical `/usr/bin/openburnbar-linux-desktop --background` command.
2. Background startup leaves the process alive without a visible window and
   registers a real StatusNotifierItem/AppIndicator with the canonical tooltip.
3. The D-Bus menu exposes Dashboard, Chat, Usage, Updates, and Settings routes;
   the production `Daemon: connected - <version>` and `Recent usage: ...`
   labels, signed-update state, and Refresh, Reconnect, and Quit actions.
4. Every route is invoked through `com.canonical.dbusmenu.Event`, renders in the
   same installed process, exposes the exact active route heading through
   AT-SPI, and produces a distinct real screenshot.
5. Keyboard focus is observable through AT-SPI after a native Tab action. A
   hidden window leaves the app alive, and the tray reopens it in the same PID.
6. Refresh advances the native DBusMenu revision. Reconnect is exercised only
   after the isolated daemon is stopped and both daemon health and the tray
   report the offline state; the restarted candidate must then return both to
   connected with another advancing DBusMenu revision. Quit terminates the
   installed process.
7. A second `--background` launch stays hidden and obtains a distinct tray
   registration, proving session persistence rather than replaying the first
   process. It is terminated before the probe exits.
8. The pre-capture desktop-process set and user-daemon active state are restored
   exactly, including failure paths.

The materialized session contains six distinct nonblank screenshots, five
route-bound AT-SPI trees, nine concrete D-Bus action receipts, four native menu
snapshots with strictly advancing revisions, the canonical package-ownership
receipt, and the signed installed manifest. Substituted actions, inactive route
trees, replayed screenshots or revisions, stale or non-production status
labels, reused registration identities, fixture markers, mismatched candidates,
or incomplete restoration fail closed.

## Live execution

Run the native probe inside the candidate's real X11 support session with a
working StatusNotifier/AppIndicator host, AT-SPI bus, D-Bus session, `xdotool`,
and `scrot`. Materialize raw output with
`materialize-p26-tray-session.mjs`, then capture the registered product proof
with `capture-p26-tray-proof.mjs`. The product validator is
`scripts/linux-port/product-validators/P-26.mjs`.

The runner refuses to interrupt an existing OpenBurnBar desktop process. It
temporarily stops the normal user daemon only if it was active, launches the
installed daemon against isolated state, and restores the original service
state in `finally`. Ambiguous `systemctl` results fail closed, and cleanup
failures are returned with the primary probe failure in an `AggregateError`.
The raw, support, and home roots must be disjoint canonical owner-only
directories; the socket, token, and index are confined to support, and unsafe
owners, modes, or symlinks are rejected. The materializer likewise confines
its output beneath the repository and rejects symlinked source or destination
paths. A live signed-candidate pass is not claimed until the generated receipt
passes the shared product-proof closure.

Wayland compositor/desktop-host coverage is a separate environment execution
concern; this standalone native adapter intentionally fails closed outside X11
instead of translating window visibility into a synthetic pass.

## Focused verification

```bash
node --test \
  scripts/linux-port/p26-native-tray-probes.test.mjs \
  scripts/linux-port/p26-tray-proof.test.mjs
```
