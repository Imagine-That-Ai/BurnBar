# Linux Wayland Computer Use CI Session Profile

This profile is evidence guidance only. It does not claim Wayland success unless the portal probes in this same run produce consent, deny, revoke, and PipeWire node artifacts.

Required surfaces:
- Wayland compositor with `WAYLAND_DISPLAY` and `XDG_SESSION_TYPE=wayland`.
- For CI, prefer `sway` with `WLR_BACKENDS=headless`, `WLR_RENDERER=pixman`, and `xdg-desktop-portal-wlr`.
- Session DBus shared by `xdg-desktop-portal`, PipeWire, and AT-SPI2.
- `xdg-desktop-portal` ScreenCast consent flow for approve, deny, revoke.
- `libei`, AT-SPI2, or `/dev/uinput` input path after local approval.

Current blocker rows are recorded in `wayland-desktop-session-profile.json` and `platform-limitation-matrix.json`.

X11 artifacts in this evidence directory are fallback-only and must not satisfy `VAL-CU-001`.
