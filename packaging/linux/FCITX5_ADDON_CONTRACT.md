# Fcitx5 addon contract

OpenBurnBar does not currently ship an Fcitx5 executable. The package carries
`fcitx5-openburnbar-addon.json` as an explicit, signed-release capability
contract so diagnostics can distinguish “Fcitx5 host installed” from “the
OpenBurnBar addon is installed”.

The contract intentionally remains unavailable until a Linux build provides
the Fcitx5Core development headers, compiles a native addon, signs its exact
installed bytes, and proves the same safety boundary as the IBus engine:

- no evdev/global key capture, clipboard reads, or surrounding-text reads;
- explicit in-app plus system-IME consent before activation;
- secure, password, and uninspectable fields denied before any write;
- bounded daemon requests, cancellation, and kill-switch teardown;
- exact package-path and release-manifest binding.

The current release therefore keeps `fcitx5` optional as an input-method host,
ships the contract for support diagnostics, and reports the addon as
unavailable. It must not be promoted to runtime support merely because the
host has `fcitx5` installed.
