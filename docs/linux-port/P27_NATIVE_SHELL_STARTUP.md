# P27 Native Shell Startup and Deep Links

This slice closes the packaging and first-launch portion of P-27 without
claiming a complete Linux notification/OAuth implementation.

## Implemented

- deb and rpm packages install the same desktop entries and
  `/etc/xdg/autostart/openburnbar.desktop` file. The AppImage carries those
  files in its payload for reproducibility, but a raw AppImage does not run a
  host package install hook; users must explicitly integrate its desktop file
  (or install the deb/rpm) before MIME/autostart registration is active.
- The desktop entry registers `x-scheme-handler/openburnbar` and forwards
  `%U` arguments to the shell.
- The autostart entry invokes `openburnbar-linux-desktop --background`.
  `--background` starts the daemon/tray lifecycle, hides the main window, and
  defaults native tracing to warnings so login does not open a dashboard or
  produce routine informational output.
- Native startup arguments are parsed before the webview starts. Only these
  routes are accepted:
  - `openburnbar://membership/success`
  - `openburnbar://membership/cancel`
  - `openburnbar://oauth/callback?code=...&state=...`
  - `openburnbar://oauth/callback?error=...&state=...` (with optional
    `error_description`)
- Host, credentials, ports, fragments, unknown query keys, duplicate keys,
  control characters, oversized values, and invalid OAuth combinations are
  rejected. The raw URL is never returned to the renderer or logged.
- The accepted handoff is read once through the typed `startup_deep_link`
  Tauri command, routed to the existing `account` hash route, and emitted as
  the `openburnbar-deep-link` browser event for the destination surface.

## Deliberate boundary

Linux currently has no single-instance/activation plugin in the shell. A
second invocation from a browser or notification therefore cannot be safely
forwarded into an already-running process; it is rejected from the first
process's trust boundary rather than pretending to support a transport that
does not exist. Full OAuth completion remains daemon-owned through its local
PKCE callback and is not inferred from a deep-link receipt. Notification
action delivery still requires the freedesktop notification adapter and
installed GNOME/KDE/wlroots evidence.

## Verification

1. Run `cargo fmt --manifest-path apps/linux-desktop/src-tauri/Cargo.toml -- --check`.
2. Run `cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --lib`.
3. Run focused Vitest for `src/deepLink.test.ts` and the existing bridge/App
   suites.
4. Run `npx tsc --noEmit`, `npm run build`, and the production bundle verifier.
5. Run `node scripts/linux-port/validate-linux-release-config.mjs` and
   `node scripts/linux-port/check-packaging-path-sync.mjs`.
6. On a clean Linux install, inspect each deb/rpm/AppImage payload for:
   `/usr/share/applications/dev.openburnbar.OpenBurnBar.desktop`,
   `/usr/share/applications/dev.openburnbar.OpenBurnBar.SafeMode.desktop`,
   `/etc/xdg/autostart/openburnbar.desktop`, and the scheme MIME entry.
7. Launch `openburnbar-linux-desktop --background` and verify no main window
   appears; select the tray Open action to reveal it.
8. Launch the packaged binary with each accepted URL and hostile variants;
   verify account routing only for accepted variants and no route change for
   rejected variants.
