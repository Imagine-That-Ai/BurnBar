# Smart Display Device QA

OpenBurnBar supports two smart-display families:

- Google Cast displays through DashCast, driven by the Mac-side Cast V2 client.
- ULANZI TC001 Pixel Clock through AWTRIX HTTP or the stock-firmware simulator.

This file is the hardware compatibility gate for future devices. A device is supported only when the same app build passes the software checks and the physical smoke test below.

## Google Cast Matrix

Test at least one device from each receiver class before calling DashCast support production-ready:

| Class | Suggested device | Why it matters |
| --- | --- | --- |
| Smart display | Google Nest Hub 2nd gen | Most common target; catches DashCast splash and ambient-mode recovery behavior. |
| Large smart display | Google Nest Hub Max | Same receiver family with different display size and power behavior. |
| Chromecast receiver | Chromecast with Google TV or Chromecast HD | Validates non-Hub Cast receivers and TV-style standby behavior. |

## DashCast Smoke Test

1. Connect the Mac and display to the same Wi-Fi network.
2. Launch the current OpenBurnBar app build.
3. Enable `Google Nest Hub` in `Settings -> Devices & Sync`.
4. Use `Make display work`. If more than one receiver is visible, pick the discovered device.
5. Verify the display leaves the DashCast splash and renders the OpenBurnBar dashboard, and verify the action reports proof that `/state.json` was polled after cast.
6. Wait 90 seconds. Verify the dashboard is still visible after at least one refresh poll.
7. Use `Refresh Hub`. Verify the dashboard updates instead of returning to the DashCast splash.
8. Interrupt the display with ambient mode or another Cast app, then run `Make display work` again. Verify OpenBurnBar recovers without manual URL edits.

The DashCast payload contract is covered by `CastChannelClientTests`. In particular, `force=true` must disable DashCast reload mode; combining `force=true` with `reload=true` is a known way to strand receivers on the DashCast splash. The runtime LOAD path also sends `reloadSeconds: 0`, which keeps DashCast's built-in periodic reload disabled — the page polls `/state.json` every 5 s on its own, has a 10-minute stale-poll `location.reload()` safety, and the Mac-side cast watchdog handles truly stuck sessions. A non-zero `reload_time` would force the Nest Hub to flash the DashCast splash on every reload, producing a continuous "displays OpenBurnBar briefly → blanks → re-displays" reset cycle.

The iOS-side bridge freshness gate (`SmartHubStore.hasLiveMacBridge`) requires a live Firestore snapshot listener on `users/{uid}/smart_hub_config/*`. A one-shot `getDocuments()` is **not** enough: the Mac re-publishes its heartbeat doc every 10 s, so without a listener the in-memory `publishedAt` goes stale 60 s after the first fetch and every Smart Display action button (including `Make display work`) flips to disabled. The companion symptom in the iPhone settings card is "Bridge offline on \<mac\>"; the fix lives in `SmartHubStore.startListening()` and runs idempotently from `load()`.

## Pixel Clock Smoke Test

1. Power the TC001 from a wall adapter, not from a laptop USB port.
2. Launch the current OpenBurnBar app build.
3. Enable `ULANZI TC001 Pixel Clock`.
4. Use `Make display work`; that is the supported one-click repair/setup path for normal users.
5. If the clock is already broadcasting an AWTRIX setup Wi-Fi network such as `awtrix_f0e1d2`, verify setup offers `Send Wi-Fi and Finish`, briefly joins that setup network, posts Wi-Fi credentials, returns to the normal network, and pushes OpenBurnBar after the clock reconnects.
6. If the clock is not already on Wi-Fi and no setup network is visible, connect it to the Mac with a data-capable USB cable. Verify setup refuses to flash phone/modem serial ports and only offers the flash path when an ESP/CP210/CH340/WCH-style clock port is present.
7. Verify setup leaves brightness at or below `PixelClockConfig.safeMaximumBrightness` before the first custom frame is pushed.
8. Verify the clock shows the OpenBurnBar provider carousel, not the stock AWTRIX screen.
9. Verify every connected quota provider appears with both short and long window pages when buckets are available.
10. Start an agent and verify the selected working spinner appears on the provider page.
11. Finish the agent and verify the optional completion sound/visual notification fires when enabled.
12. Press the clock's Left/Right hardware buttons after the display has been idle for several minutes. Verify they move to the previous/next provider page instead of reloading the same page.

TC001 prevention rule: never push a dense bitmap while brightness is high. The firmware can become temporarily unreachable under high LED load, especially on marginal USB power. OpenBurnBar keeps pixel-clock brightness in a visible safe range and applies brightness before custom app writes so future setup flows fail visible instead of blanking or flapping the hardware.

USB visibility rule: a powered TC001 is not necessarily a data-connected TC001. The built-in battery and blue indicator can make the clock look alive while the Mac still has no USB data path. The Mac must see either an AWTRIX LAN endpoint, an AWTRIX setup Wi-Fi SSID, or an ESP/CP210/CH340/WCH-style serial device. If the clock lights up but none of those exists, treat the cable/path as power-only from software's perspective and do not flash. For normal daily use, prefer stable wall power plus Wi-Fi control; reserve direct data USB for flashing or recovery.

Repair-status rule: every smart-display repair action must produce a `SmartDisplayDeviceRepairStatus`. A command sent to a receiver is not success by itself; success requires a healthy status with real proof, such as a Nest Hub polling `/state.json` or a Pixel Clock accepting an AWTRIX custom app / stock simulator frame.

## Purchase Guidance

If buying additional devices, buy one Nest Hub 2nd gen first and one Chromecast with Google TV second. Add a Nest Hub Max when large-display layout confidence matters. That set covers the receiver behaviors most likely to break the DashCast path.
