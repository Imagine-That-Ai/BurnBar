# P-36 installed visual and interaction polish proof

P-36 is a standalone installed-candidate closure for responsive density and interaction quality. It launches the package-owned Tauri/WebKitGTK shell with fixture mode disabled and binds every screenshot, AT-SPI tree, DOM geometry receipt, restart, and package fact to the signed release closure.

The production runner converges the WebDriver outer window until the measured DOM viewport is exactly compact `720x900`, standard `1180x820`, or wide `1600x900`. Each size must have no horizontal document overflow, ancestor-clipped controls, or overlapping interactive controls and must preserve usable control height. Five distinct nonblank WebKitGTK viewport screenshots cover compact light, standard dark, wide dark, reduced motion, and the open keyboard-driven overflow menu.

Light and dark are selected through the product overflow control, persisted in product storage, verified on another route, and checked again after restart. Every visible native control must expose the matching WebKitGTK color scheme and a finite foreground/background contrast measurement of at least 4.5:1. Reduced motion uses an isolated GLib keyfile backend rather than mutating the operator's desktop. This works through WebKitGTK on GNOME, KDE, and Sway, must activate `(prefers-reduced-motion: reduce)`, and must leave zero running animations or transitions before restoration.

Keyboard proof reaches the overflow trigger using WebDriver Tab actions, verifies `:focus-visible`, opens it with Enter, changes menu focus with ArrowDown, closes with Escape, and verifies trigger-focus restoration before reopening it for capture. One installed-shell restart must preserve both computed and stored dark appearance plus stable standard geometry. The exact daemon state, desktop process set, motion preference, and isolated home are restored on success or failure.

```bash
node --test scripts/linux-port/p36-visual-polish-proof.test.mjs scripts/linux-port/ownership-tests/P-36.test.mjs
```

The default runner requires a signed installed candidate, live supported Linux desktop, `tauri-driver`, `WebKitWebDriver`, AT-SPI, and `gsettings` with the GLib keyfile backend. Screenshots come from the WebDriver viewport, so the proof has no compositor-specific screenshot dependency. Dependency injection is test-only.
