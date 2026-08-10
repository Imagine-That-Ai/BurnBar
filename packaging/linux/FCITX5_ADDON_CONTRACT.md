# Fcitx5 addon contract

OpenBurnBar ships a **native Fcitx5 addon**
(`packaging/linux/fcitx5-addon/`, built by
`scripts/linux-port/build-fcitx5-addon.sh` against `Fcitx5Core >= 5.1.6`).
The DEB, RPM, and Arch packages install:

- `/usr/lib/openburnbar/fcitx5/openburnbar-fcitx5.so` - the addon module,
  built per-architecture in the pinned Linux toolchain container;
- `/usr/share/openburnbar/text-expansion/fcitx5/addon/openburnbar-fcitx5.conf`
  and `.../inputmethod/openburnbar.conf` - Fcitx5 registration metadata
  (Arch installs stable symlinks into `/usr/lib/fcitx5` and
  `/usr/share/fcitx5`; DEB/RPM register via
  `packaging/linux/openburnbar-fcitx5-register.sh`, and
  `openburnbar-fcitx5-unregister.sh` removes only our own symlinks on
  uninstall, restoring the previously configured engines);
- `/usr/share/openburnbar/text-expansion/text-expansion-engine-fcitx5.json`
  - the release-signed executable manifest binding the addon exact bytes
  and installed path (signed by the same isolated Ed25519 release signer as
  the IBus engine manifest);
- `/usr/share/openburnbar/text-expansion/fcitx5-openburnbar-addon.json` -
  the machine-readable capability contract used by diagnostics and the
  shell capability readback.

The addon proves the same safety boundary as the IBus engine:

- **trigger-only**: it observes only keys typed while the OpenBurnBar engine
  is the active Fcitx5 input method - no evdev/global key capture, no
  XRecord/XTest, no clipboard reads, no surrounding-text reads;
- **daemon-owned expansion**: triggers are forwarded to
  `openburnbar-cli text-expansion-engine-expand` under a hard timeout with a
  bounded response; the daemon refuses until external expansion is
  explicitly enabled (consent) and its kill switch halts the lane;
- **secure fields denied first**: password/sensitive capability flags and
  fields that have not published capability metadata are denied before any
  daemon call (`deny-unless-inspectable-and-explicitly-nonsecure`);
- **signed registration**: the daemon Linux adapter refuses to treat the
  backend as registered unless the signed manifest matches the module exact
  bytes, path identity, owner-safe permissions, and backend
  (`text-expansion-engine-fcitx5.json` cannot be satisfied by the IBus
  manifest or vice versa);
- **restart/upgrade/uninstall**: a crashed fcitx5 restarts via the desktop
  session as usual and simply reloads the addon; upgrades replace the module
  and its signed manifest atomically through the package manager; uninstall
  removes the module, registration links, and manifest, leaving the user
  prior engine configuration untouched.

The AppImage carries the addon as payload for the Arch recipe but performs
**no** system input-method registration: a transient mount path cannot
satisfy the signed manifest path identity, matching the IBus rule.

IBus remains fully supported and the default backend
(`packaging/linux/openburnbar-text-expansion-engine.py`,
`packaging/linux/ibus-openburnbar.xml`).

`scripts/linux-port/validate-fcitx5-addon-source.mjs` enforces this contract
in CI: source safety markers, packaging wiring across DEB/RPM/Arch/AppImage,
release-manifest consistency, and stale-wording rejection.
