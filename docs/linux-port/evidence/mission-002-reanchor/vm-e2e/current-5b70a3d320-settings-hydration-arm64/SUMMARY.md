# Linux arm64 installed candidate receipt

This is a non-certifying live receipt for source commit `5b70a3d320` in the
Ubuntu 24.04.4 GNOME/X11 UTM guest at `192.168.64.5`.

The exact arm64 DEB (`86d94c8322af6dfc9331ffd0b911c3645ac58a736234390e2e15e014223fdc46`,
151,412,092 bytes) is installed and the foreground desktop is running from
`/usr/bin`. The package-owned daemon is active and CLI health is green.

The live Settings regression is closed: AT-SPI activates Settings, the route
exposes 105 nodes and 50 actionable controls, no `Loading Settings` node
remains, the daemon loads 21 providers, General exposes the startup checkbox,
and Media & Sharing opens with its `Open Media` link. The root cause was the
packaged route's idle deferral preventing Settings from mounting; the fix is in
`2f75f3269e`, with eager inner hydration in `5b70a3d320`.

Source gates are green at 83 frontend files/793 tests, focused Settings/route
coverage 45/45, Tauri Rust 125/125, TypeScript, formatting, and production
bundle verification. The connected physical iPad focused navigation suite also
passed with xcodebuild exit 0.

The live-kernel probe is recorded in
[`live-kernel-check.json`](live-kernel-check.json): two X11 screenshots two
seconds apart changed 406,879 pixels, proving the Canvas2D fallback is
animating. The VM's virgl path exposes OpenGL ES 3.0 and WebKit reports a GBM
context fallback, so WebGL2-only kernels are not certified on this guest and
may resolve to the default 2D kernel.

This receipt does not certify parity. The strict product ledger remains 0/40
and the environment ledger remains 0/7 until signed provenance, production
deployment, enrollment/approval, two-device Mercury and Browser Computer Use,
and the KDE/Wayland/wlroots/accessibility/performance matrix are completed.
