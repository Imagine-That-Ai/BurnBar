# `windows/pal/` — Platform Abstraction Layer (W1)

The **Platform Abstraction Layer** — the seam layer the shell and engine call instead of Win32
directly: filesystem paths, secret store (CNG/TPM-backed key + DPAPI outer wrap), process/ConPTY,
named-pipe IPC, toasts, tray, filesystem watchers, autolaunch, global hotkey, single-instance guard,
mDNS/Bonjour discovery, and the self-signature check. Each seam freezes under a semver contract on
its second real consumer (see the master plan §6).

**Status:** skeleton placeholder. PAL library + contract projects land here and register into
[`../OpenBurnBar.sln`](../OpenBurnBar.sln).

Source files here are ratcheted by the per-tree budget under the `pal` area.
