# Live Linux receipt: `b590d5a77`

This receipt records the exact arm64 DEB rebuilt from the current parity branch
after the media lifecycle, Media & Sharing settings, and onboarding Secret
Service cleanup slices were integrated. It was installed in the running Ubuntu
24.04.4 GNOME/X11 UTM guest at `192.168.64.5`.

Package, daemon, desktop, service, GStreamer, Secret Service, IBus, and
foreground AT-SPI checks passed. The source gates passed at this head: 83
desktop test files / 787 tests, TypeScript, production bundle verification,
125/125 Tauri Rust tests, 28/28 Insights, 31/31 SettingsSurface,
39/39 bridge/settings, 8/8 onboarding, and media lifecycle 6/6 with GStreamer
plus 5/5 without it.

This is engineering evidence only. It is deliberately **non-certifying**:
the DEB is unsigned, the Settings route remained in a bounded loading state
before direct Launch at login/Media control activation, the headless
framebuffer screenshot was black, and no cross-device iPad/Linux workflow or
seven-environment matrix was run.

Machine-observed details are in
[`live-installed-receipt.json`](live-installed-receipt.json).
