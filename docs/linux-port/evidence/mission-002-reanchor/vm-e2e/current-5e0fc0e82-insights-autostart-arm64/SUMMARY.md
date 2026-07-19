# Live Linux receipt: `5e0fc0e82`

This receipt records the exact arm64 DEB built from source commit `5e0fc0e82`
and installed in the running Ubuntu 24.04.4 GNOME/X11 UTM guest at
`192.168.64.5`.

The package, daemon, desktop, service, GStreamer runtime, Secret Service, IBus,
and foreground AT-SPI tree checks passed. The desktop process stayed up with
one live process and no fatal/stub log matches. The source gates were green
before packaging:
83 desktop test files / 785 tests, TypeScript, production bundle verification,
125/125 Tauri Rust tests, and the focused Insights/autostart/settings suites.

This is engineering evidence only. It is deliberately **non-certifying**:
the DEB is unsigned, the background-only autostart tree was initially too
shallow, the bounded Settings route remained in a loading state before its
Launch at login control could be activated, the headless framebuffer
screenshot was black, and no cross-device iPad/Linux workflow or
seven-environment matrix was run.

Machine-observed details are in
[`live-installed-receipt.json`](live-installed-receipt.json).
