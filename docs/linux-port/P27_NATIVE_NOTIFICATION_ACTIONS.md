# P27 Native Notification Actions

The Linux desktop shell exposes a typed `native_notification_show` Tauri command
for user-facing freedesktop notifications. Requests are limited to registered
routes and the `open` action; IDs and text are bounded before they cross the
native boundary. The shell probes `org.freedesktop.Notifications` through
`notify-rust` and attaches the `open` action only when the server advertises the
`actions` capability.

When the notification service is unavailable, the command returns
`delivered: false` with a degraded reason. When body notifications work but
actions are not advertised, the result keeps `delivered: true` and explicitly
returns `actionsAttached: false` plus `native_notification_actions_unavailable`.
The renderer still validates the route/action event before changing its hash.
No notification click dispatches an arbitrary URL, shell command, or
unregistered route.

The existing Tauri global-shortcut plugin registers the two Computer Use panic
chords and `Ctrl+Alt+Super+O` (open dashboard) in one plugin instance. The
`native_shortcut_status` command reports registration and host failure state;
the shell never reports success when plugin setup fails (for example on a
compositor without a supported global-key backend).

## QA

1. Run `native_notification_capabilities` on GNOME, KDE, and a wlroots session;
   verify the capability list is source-backed.
2. Send a typed `chat/open` request; click **Open** and verify only the chat
   route is selected after the window is restored.
3. Repeat with an action-less notification server; verify the body is visible,
   `actionsAttached` is false, and the UI exposes the degraded reason.
4. Send malformed route/action, control-character, oversized, and unsafe-ID
   requests; verify native validation rejects them before delivery.
5. Query `native_shortcut_status`, press `Ctrl+Alt+Super+O`, and verify the
   dashboard reopens. On a host where registration fails, verify the status is
   unavailable/degraded and no shortcut success is shown.
