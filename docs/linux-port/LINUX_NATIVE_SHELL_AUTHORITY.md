# Linux native shell authority

Status: source-level native shell, compact status window, and freedesktop
notification action primitives implemented; the desktop-matrix harness now
requires native-shell evidence before a row can become ready. Installed desktop
matrix proof, provider OAuth return, and cloud agent-reply inline-reply parity
remain open.

This document records the native shell contract introduced for
`LNX-NATIVE-001`. It covers process ownership, background launch, typed deep
links, the live tray, the compact status window, source-level freedesktop
notifications, and user-scoped XDG login start. It does not claim that the
cloud agent-reply listener/inline reply path, an OAuth provider-return matrix,
or every Linux tray host is complete. The matrix gate now prevents those source
capabilities from being promoted without installed desktop evidence.

## Authority boundary

Rust owns all OS-provided launch arguments, single-instance arbitration, tray
events, window activation, and autostart file mutation. The renderer receives
only typed data:

- `NativeDeepLink { route, action }`
- `NativeShellSnapshot`
- `NativeTraySnapshot`
- `NativeStatusSnapshot { shell, tray }`
- `NativeNotificationCapabilities`
- `NativeNotificationResult`

Raw URLs and filesystem write paths do not cross into renderer-owned logic.
The TypeScript bridge independently validates each route, action, route/action
pair, boolean, counter, freshness state, notification capability, delivery
result, and optional degradation reason.

## Launch and single-instance behavior

`--background` starts the primary window hidden while keeping the tray and
daemon data supervisor active. `tauri-plugin-single-instance` sends later
launch arguments to the existing process:

| Secondary launch | Result |
|---|---|
| No special argument | Show and focus the dashboard. |
| `--background` only | Keep the existing instance; do not force the window forward. |
| Valid `openburnbar://` URL | Show the window and dispatch the typed route/action. |
| Invalid or unknown URL | Reject it without renderer delivery or external navigation. |

The renderer installs its native-event listener before it calls
`native_shell_ready`. Rust queues initial and early secondary links until that
ready transition, then drains the queue exactly once. Later links emit through
the same typed event. This ordering closes the launch-time listener race.

## Deep-link allowlist

The native parser accepts at most 2,048 characters, the exact `openburnbar`
scheme, and no user info, password, port, query, fragment, or control character.

| URL | Renderer result |
|---|---|
| `openburnbar://dashboard` | `overview / open-dashboard` |
| `openburnbar://search` | `activity / open-search` |
| `openburnbar://chat` | `chat / open-chat` |
| `openburnbar://insights`, `/today`, `/year` | `insights / open-insights` |
| `openburnbar://membership`, `/success` | `account / membership-success` |
| `openburnbar://membership/cancel` | `account / membership-cancel` |

Provider/account OAuth callbacks with state or authorization material are not
accepted by this generic route. That flow remains owned by `LNX-AUTH-001` and
must use a dedicated native validator before it can be added.

## Live tray

The tray menu exposes stable native actions for dashboard, chat, providers,
updates, daemon reconnect, login start, and quit. Disabled status rows show:

- daemon freshness: live, stale, offline, or unavailable;
- today's bounded cost and token count;
- the lowest remaining quota among usable provider buckets;
- connected provider count.

The renderer derives those facts from the same authoritative usage, provider,
and health stores as the mounted app. Refreshes are single-flight and coalesced,
and daemon health/subscription events wake the tray supervisor. A failed data
read produces unavailable state instead of preserving a false live label.

Left-clicking the tray icon opens the singleton compact status window; the menu
also exposes "Open quick status" for hosts that do not deliver a normal left
click. GNOME icon-only behavior, StatusNotifier/AppIndicator host loss,
keyboard/screen-reader access in installed sessions, and tray crash recovery
remain installed-product certification rows. The menu does not yet provide
macOS-equivalent account quick switching.

## Compact status window

Rust lazily creates one `status` webview at `index.html?surface=status`, sized
for a compact native utility window and hidden instead of destroyed on close.
The window boots a lightweight React surface rather than the full dashboard
shell. It reads `native_status_snapshot`, listens for `native-status-snapshot`
events emitted after accepted tray updates, and uses `native_status_route` for
all quick actions. That Rust command reuses the same route/action allowlist as
tray and notification actions before showing the main window.

The status window shows:

- today's cost and token count;
- connected provider count;
- quota-floor percentage or an honest none state;
- live, stale, offline, or unavailable freshness;
- notification capability/degradation state;
- dashboard, chat, provider, update, and reconnect actions.

It has a semantic `main`, a heading, status text, named buttons, an accessible
close control, an Escape close path, stable dimensions, and responsive wrapping
for narrow/high-scale text.

## Freedesktop notifications

Linux notification delivery is exposed as typed native commands:

- `native_notification_capabilities`
- `native_notification_show`

The implementation uses `notify-rust` and the freedesktop
`org.freedesktop.Notifications` D-Bus server on Linux. Payloads are bounded and
accept only known route/action pairs. The D-Bus response listener runs off the
blocking wait path, then marshals open/default actions back to Tauri's main
thread before showing the main window and delivering the typed deep link.

When a notification server is absent, when the host is not Linux, or when action
buttons are not supported, the command returns an explicit degraded result
instead of claiming delivery. Inline text reply is not implemented here because
the macOS path depends on Firebase `agent_notification_events`,
`agent_notification_replies`, CloudVault sealing, and App Check. Linux still
needs a cloud event listener and reply sealer before agent-reply inline reply
can be claimed.

## Login start

Settings and the tray mutate the same user-scoped entry:

```text
${XDG_CONFIG_HOME:-$HOME/.config}/autostart/dev.openburnbar.OpenBurnBar.desktop
```

The config root must be absolute. Enabling login start creates the autostart
directory with mode `0700`, writes a mode `0600` temporary file, syncs it, and
atomically renames it into place. The enabled state is true only when the file
exactly matches `packaging/linux/autostart/openburnbar.desktop`; malformed or
locally changed content is never reported as OpenBurnBar-owned enabled state.
Disabling removes only that exact user-scoped path and treats absence as success.

deb, rpm, and AppImage bundles install the canonical reference at
`/usr/share/openburnbar/autostart/openburnbar.desktop`. The AUR package installs
the same bytes. `check-packaging-path-sync.mjs` fails if its packaging copy
drifts from the canonical source.

## Verification

Focused source checks:

```bash
cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --locked
npx --prefix apps/linux-desktop tsc --noEmit -p apps/linux-desktop/tsconfig.json
npm test --prefix apps/linux-desktop -- --run \
  src/state/nativeShellSupervisor.test.ts \
  src/surfaces/settings/SettingsSurface.test.tsx \
  src/tauriBridge.test.ts
node scripts/linux-port/check-packaging-path-sync.mjs
node scripts/linux-port/validate-linux-release-config.mjs
```

Coverage includes hostile URL rejection, typed route/action correlation,
listener-before-drain ordering, refresh coalescing, freshness projection,
compact status decoding/rendering/actions, freedesktop notification payload
bounds/action routing, XDG path rejection, exact autostart round-trip and
permissions, Settings mutation, and packaging-copy equality.

An ARM64 Ubuntu 24.04 GNOME X11 runtime pass also exercised the
production-protocol executable with SHA-256
`cfc14d7da1124d32d2370adf515cf4636b7c1c0345376377f71d09bd0099608d`.
It proved a hidden background launch, one-process `openburnbar://chat` routing,
the bundled tray icon and exported native menu, honest daemon-offline labels,
and a native-menu login-start off/on/off round trip. The created user entry was
mode `0600`, user-owned, and byte-identical to the canonical packaging entry.
See `evidence/mission-003-native-shell/runtime-transcript.txt` and the adjacent
GNOME X11 screenshots. This is direct executable evidence, not installed
package or desktop-matrix certification.

## Desktop matrix evidence contract

`scripts/linux-port/run-linux-matrix-harness.mjs` requires three external
evidence files before a requested support row can become `ready`:

- `OPENBURNBAR_LINUX_INSTALLED_EVIDENCE`
- `OPENBURNBAR_LINUX_ACCESSIBILITY_EVIDENCE`
- `OPENBURNBAR_LINUX_NATIVE_SHELL_EVIDENCE`

The native-shell evidence must be valid JSON with `passed: true`, the exact
current git commit under `git.commit` or `commit`, and, when `--environment` is
used, an `environmentId` matching the requested support row. It must also prove
all of these checks either as booleans on `nativeShell` or as passed entries in
a `checks` array:

| Check id | Required proof |
|---|---|
| `tray-host` | StatusNotifier/AppIndicator host renders the installed tray affordance. |
| `tray-actions` | Tray dashboard/chat/provider/update/reconnect/login-start/quit actions route correctly. |
| `compact-status-window` | Compact native status window opens, refreshes, and closes without mounting the full shell. |
| `status-window-a11y` | Compact status window is keyboard and assistive-technology reachable. |
| `notification-server` | Freedesktop notification server capability is detected honestly. |
| `notification-actions` | Notification actions deliver only allowlisted native route/action pairs. |
| `notification-relaunch-route` | Notification activation relaunches or focuses the installed app and routes correctly. |
| `deep-link-relaunch` | Secondary `openburnbar://` launches reuse the existing instance and route correctly. |
| `login-start` | XDG login-start enable, relogin, disable, stale-file, and uninstall paths are proven. |
| `tray-host-loss-recovery` | Tray host loss, crash, or restart recovers without stale status or orphaned actions. |

`verify-shell-evidence.mjs` now writes this matrix input as
`native-shell-evidence.json` in the evidence directory. VM jobs should set
`OPENBURNBAR_LINUX_MATRIX_ENVIRONMENT` or `OB_LINUX_ENVIRONMENT_ID` to the
support-row id before running the verifier. Jobs that want the shell verifier
itself to fail, rather than letting the matrix harness consume the blocked
artifact, can set `OPENBURNBAR_REQUIRE_NATIVE_SHELL_EVIDENCE=1`.

The producer reads these installed-session artifacts:

| Check id | Evidence files |
|---|---|
| `tray-host` | `tray-registered-items.txt`, `tray-status-notifier-introspection.txt` |
| `tray-actions` | `tray-menu-actions.json`, `tray-action-route-results.json`, `tray-open-menu-event.txt`, `tray-chat-menu-event.txt`, `tray-providers-menu-event.txt`, `tray-updates-menu-event.txt`, `tray-reconnect-menu-event.txt`, `tray-login-start-menu-event.txt`, `tray-quit-menu-event.txt` |
| `compact-status-window` | `native-status-window-report.json`, `screenshot-native-status-window.png` |
| `status-window-a11y` | `native-status-window-a11y.json` |
| `notification-server` | `native-notification-capabilities.json` |
| `notification-actions` | `native-notification-action-result.json` |
| `notification-relaunch-route` | `native-notification-relaunch-route.json` |
| `deep-link-relaunch` | `native-deep-link-relaunch.json` |
| `login-start` | `native-login-start-roundtrip.json` |
| `tray-host-loss-recovery` | `tray-host-loss-recovery.json` |

`scripts/linux-port/linux-desktop-session.sh` now emits the tray-host,
tray-actions, compact-status-window, status-window-a11y, deep-link-relaunch,
and partial login-start artifact inputs from a real installed `.deb` session:
D-Bus menu activation must return successfully, route actions must create fresh
`route.navigation` samples summarized in `tray-action-route-results.json`,
quick status must open/close with screenshot and AT-SPI focus evidence, and
secondary `openburnbar://chat` launch must exit via single-instance handoff
while the original process stays alive. The
`native-login-start-roundtrip.json` produced by this session intentionally
remains `passed: false` until a dedicated lifecycle harness proves relogin and
package-uninstall removal.

Missing, stale, wrong-environment, or partially passed native-shell evidence
blocks the row even when package and accessibility evidence are present.

## Remaining certification

`LNX-NATIVE-001`, `P-26`, `P-27`, and `GAP-014` remain open until an exact
installed candidate passes:

1. rich and icon-only tray hosts on GNOME Wayland, KDE Wayland, X11, and the
   declared wlroots fallback;
2. login, logout/login, disabled login start, stale file replacement, crash,
   reinstall, upgrade, and uninstall behavior;
3. launch-before-renderer, repeated secondary launch, hostile URL, membership
   return, focus, workspace, and multi-monitor cases;
4. keyboard, screen-reader, reduced-motion, high-contrast, and 200% text rows;
5. freedesktop actionable notification delivery in rich and action-limited
   hosts, relaunch routing, denial, daemon-offline behavior, and
   notification-server absence;
6. portal/global shortcut and existing daemon-backed panic latency without the
   tray becoming a sole safety path.
7. cloud agent-reply notification listener, App Check, CloudVault reply sealing,
   and inline reply send/open parity with macOS.

The source foundation is complete only for the capabilities described above.
Installed notification behavior, provider OAuth return, cloud inline reply, and
the final desktop matrix must remain visibly blocked until their product
evidence exists.
