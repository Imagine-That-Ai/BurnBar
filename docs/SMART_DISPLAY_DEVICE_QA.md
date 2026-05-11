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
4. Run setup and pick the discovered device.
5. Verify the display leaves the DashCast splash and renders the OpenBurnBar dashboard.
6. Wait 90 seconds. Verify the dashboard is still visible after at least one refresh poll.
7. Use `Refresh Hub`. Verify the dashboard updates instead of returning to the DashCast splash.
8. Interrupt the display with ambient mode or another Cast app, then wait for the watchdog. Verify OpenBurnBar recovers without another manual setup.

The DashCast payload contract is covered by `CastChannelClientTests`. In particular, `force=true` must disable DashCast reload mode; combining `force=true` with `reload=true` is a known way to strand receivers on the DashCast splash.

## Pixel Clock Smoke Test

1. Power the TC001 from a wall adapter, not from a laptop USB port.
2. Launch the current OpenBurnBar app build.
3. Enable `ULANZI TC001 Pixel Clock`.
4. Run the one-click setup flow.
5. If the clock is already broadcasting an AWTRIX setup Wi-Fi network such as `awtrix_f0e1d2`, verify setup offers `Send Wi-Fi and Finish`, briefly joins that setup network, posts Wi-Fi credentials, returns to the normal network, and pushes OpenBurnBar after the clock reconnects.
6. If the clock is not already on Wi-Fi and no setup network is visible, connect it to the Mac with a data-capable USB cable. Verify setup refuses to flash phone/modem serial ports and only offers the flash path when an ESP/CP210/CH340/WCH-style clock port is present.
7. Verify setup leaves brightness at or below `PixelClockConfig.safeMaximumBrightness` before the first custom frame is pushed.
8. Verify the clock shows the OpenBurnBar provider carousel, not the stock AWTRIX screen.
9. Verify every connected quota provider appears with both short and long window pages when buckets are available.
10. Start an agent and verify the selected working spinner appears on the provider page.
11. Finish the agent and verify the optional completion sound/visual notification fires when enabled.

TC001 prevention rule: never push a dense bitmap while brightness is high. The firmware can become temporarily unreachable under high LED load, especially on marginal USB power. OpenBurnBar keeps pixel-clock brightness in a visible safe range and applies brightness before custom app writes so future setup flows fail visible instead of blanking or flapping the hardware.

USB visibility rule: a powered TC001 is not necessarily a data-connected TC001. The built-in battery and blue indicator can make the clock look alive while the Mac still has no USB data path. The Mac must see either an AWTRIX LAN endpoint, an AWTRIX setup Wi-Fi SSID, or an ESP/CP210/CH340/WCH-style serial device. If the clock lights up but none of those exists, treat the cable/path as power-only from software's perspective and do not flash. For normal daily use, prefer stable wall power plus Wi-Fi control; reserve direct data USB for flashing or recovery.

## Purchase Guidance

If buying additional devices, buy one Nest Hub 2nd gen first and one Chromecast with Google TV second. Add a Nest Hub Max when large-display layout confidence matters. That set covers the receiver behaviors most likely to break the DashCast path.
