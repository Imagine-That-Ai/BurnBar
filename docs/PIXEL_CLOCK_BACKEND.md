# Pixel Clock Backend Contract

OpenBurnBar supports ULANZI TC001 Pixel Clock control through AWTRIX HTTP firmware. The Mac owns all LAN writes to the clock; iPhone and iPad publish owner-scoped Firestore actions that the Mac listens for.

## Shared Model

- `PixelClockConfig`: host, port, layout, palette, period, cadence, brightness, provider filter, configurable working-spinner style/colors, agent-completion alert toggles, and last probe status.
- `PixelClockQuotaRenderer`: turns provider quota and agent-status snapshots into AWTRIX custom app payloads for `openburnbar`. The default `providerDashboard` layout draws asset-derived provider marks on the left, keeps the time-window label and quota bar on the right, and draws the user-selected spinner on every provider page whose agent status is `running`. Idle text is intentionally omitted so the logo has the most room on the 32x8 matrix.
- `PixelClockSettingsModel`: cross-platform settings state model. Platform adapters implement `PixelClockOperations`.

## Firestore

- Config lives at `users/{uid}/smart_hub_config/{deviceId}` under the `pixelClock` field.
- Commands live at `users/{uid}/smart_display_actions/{actionId}` with `type`, `status`, timestamps, and optional `pixelClock`.
- Rules validate every nested `pixelClock` field and reject secret-like top-level payload keys.

## macOS Runtime

- `PixelClockController` discovers and probes AWTRIX, renders quota/dashboard pages, applies optional brightness, pushes `/api/custom?name=openburnbar`, sends `/api/notify` tests, and removes the app.
- Agent-completion notifications call `PixelClockController.notifyAgentCompletion(...)`. AWTRIX Light receives a provider-specific `/api/notify` payload with a sound name such as `codex`, `claude`, `droid`, `cursor`, `minimax`, or `zai`; stock ULANZI firmware receives the matching visual frame through the local simulator path.
- `PixelClockAgentStatusStore` is the Mac-local working-state source for the clock. CLI launches mark Codex, Claude Code, and OpenClaw as `running`; process exit records `completed` or `failed`; daemon completion notifications record provider-specific `completed` pages. The Pixel Clock carousel includes every quota-signal provider so users can see READY/RUN/DONE/ERR status for each agent, even before a quota API has produced a bucket.
- `PixelClockStockSimulatorServer` is the Mac-side AWTRIX simulator for stock ULANZI firmware. It listens on `7001`, accepts the stock firmware's MQTT connection, acknowledges `awtrixmatrix/#` subscriptions, and publishes rendered OpenBurnBar frames on `awtrixmatrix/a`.
- Discovery probes the configured host first, uses AWTRIX Bonjour records when available, then scans the Mac's active LAN netmask plus the known TC001 default at `192.168.68.92`. `/api/stats` must return AWTRIX-shaped JSON before a host is treated as the clock; generic JSON endpoints are rejected so other LAN services cannot be mistaken for the TC001. When a clock is found at a new DHCP address, the Mac persists that host/port back into `PixelClockConfig` before test, push, or remove operations.
- `preparePixelClock` is the one-button setup path for users. It probes the clock, distinguishes AWTRIX Light from stock ULANZI firmware, and returns a `PixelClockSetupResult` with a setup mode, human-readable message, optional Mac LAN host/port, optional AWTRIX setup SSID, and the AWTRIX flasher URL.
- On AWTRIX Light firmware, `preparePixelClock` applies brightness and reports `awtrixLightReady`; all direct OpenBurnBar quota pushes use AWTRIX HTTP.
- On stock ULANZI firmware, `preparePixelClock` posts the stock settings form to enable Awtrix Simulator, points it at the Mac's current LAN IPv4 address on port `7001`, enables Show Local IP, starts the local MQTT simulator, and reports `stockSimulatorConfigured`. Users do not need to flash AWTRIX Light for the stock Ulanzi path.
- If the clock is not on LAN but is broadcasting an AWTRIX setup Wi-Fi network such as `awtrix_f0e1d2`, setup reports `needsWiFiProvisioning`. The Mac then prompts once for the user's 2.4 GHz Wi-Fi credentials, briefly joins the setup network, posts credentials to `192.168.4.1`, returns to the normal network, and pushes OpenBurnBar after the clock reconnects.
- If the clock is neither reachable on LAN, visible as an AWTRIX setup Wi-Fi network, nor visible as a real ESP/CP210/CH340/WCH-style USB serial device, setup reports `unreachable` instead of flashing. On macOS, the one-click setup card then waits briefly and retries so users can plug in the clock or let Wi-Fi finish reconnecting without starting over. Known non-clock USB serial devices such as Samsung/Android phones are filtered out before the flasher can run, and the setup result distinguishes “no USB data connection” from “USB is present but it is not the clock.”
- When stock firmware is present but the Mac cannot determine a usable LAN IPv4 address, `preparePixelClock` reports `needsAwtrixLightFlash` and includes the flasher URL so the UI can make the next step explicit.
- `SmartDisplayConfigPublisher` publishes the local `PixelClockConfig` alongside the existing Nest Hub config.
- `SmartDisplayActionsListener` consumes mobile actions and marks them `completed` or `failed`. For `pixel_clock_prepare`, it writes the Mac-side setup fields back onto the same action document, including `setupSSID` when an AWTRIX setup network is visible, so iPhone and iPad can show exact next steps instead of a generic permissions or timeout error.
- Google Nest Hub detection still uses `_googlecast._tcp.local.` mDNS first, but Cast actions now persist the last resolved host/port and fall back to that endpoint when a later mDNS pass misses the device. The bridge URL prefers the Mac's LAN IPv4 address before `.local` so Nest devices do not depend on resolving the Mac hostname.

## Mobile Runtime

- `SmartHubStore` decodes/publishes `pixelClock`, updates the freshest smart hub config doc, and emits `smart_display_actions`.
- `SmartHubStore` keeps the last completed action payload in memory so mobile adapters can read setup-mode, probe-status, server-host, server-port, and flasher fields written by the Mac.
- `MobilePixelClockOperationsAdapter` binds shared settings logic to `SmartHubStore` and maps `pixel_clock_prepare` results into `PixelClockSetupResult` for the shared settings UI.
- iPhone and iPad settings publish the same spinner and completion-alert fields as macOS. The macOS listener decodes these fields from mobile `smart_display_actions`, so changing spinner colors, spinner type, Pixel Clock sound, or local completion notifications from mobile applies to the Mac-controlled clock path without a separate pairing step.

The stock ULANZI firmware is detected as `stockUlanziFirmware`; OpenBurnBar handles it by running the local AWTRIX simulator broker on the Mac. If the stock setup fails, present it as a LAN/Mac-listener issue, not as a mobile permissions failure.
