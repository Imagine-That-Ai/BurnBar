# Linux native shell authority

Status: implemented foundation; freedesktop notifications and installed desktop
matrix certification remain open.

This document records the native shell contract introduced for
`LNX-NATIVE-001`. It covers process ownership, background launch, typed deep
links, the live tray, and user-scoped XDG login start. It does not claim that
freedesktop notifications, an OAuth provider-return matrix, a compact status
window, or every Linux tray host is complete.

## Authority boundary

Rust owns all OS-provided launch arguments, single-instance arbitration, tray
events, window activation, and autostart file mutation. The renderer receives
only typed data:

- `NativeDeepLink { route, action }`
- `NativeShellSnapshot`
- `NativeTraySnapshot`

Raw URLs and filesystem write paths do not cross into renderer-owned logic.
The TypeScript bridge independently validates each route, action, route/action
pair, boolean, counter, freshness state, and optional degradation reason.

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

The menu does not yet provide macOS-equivalent account quick switching or the
compact rich status window. GNOME icon-only behavior, StatusNotifier/AppIndicator
host loss, multi-monitor placement, keyboard/screen-reader access, and tray
crash recovery remain installed-product certification rows.

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
listener-before-drain ordering, refresh coalescing, freshness projection, XDG
path rejection, exact autostart round-trip and permissions, Settings mutation,
and packaging-copy equality.

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
5. freedesktop actionable notification delivery, relaunch routing, denial,
   daemon-offline behavior, and notification-server absence;
6. portal/global shortcut and existing daemon-backed panic latency without the
   tray becoming a sole safety path.

The source foundation is complete only for the capabilities described above.
Notification delivery and the final desktop matrix must remain visibly blocked
until their product evidence exists.
