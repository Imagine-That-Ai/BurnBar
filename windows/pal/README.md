# `windows/pal/` — Platform Abstraction Layer (W1)

The **Platform Abstraction Layer** — the seam layer the shell and engine call instead of Win32
directly: filesystem paths, secret store (CNG/TPM-backed key + DPAPI outer wrap), process/ConPTY,
named-pipe IPC, toasts, tray, filesystem watchers, autolaunch, global hotkey, single-instance guard,
mDNS/Bonjour discovery, and the self-signature check. Each seam freezes under a semver contract on
its second real consumer (see the master plan §6).

**Status:** skeleton placeholder. PAL library + contract projects land here and register into
[`../OpenBurnBar.sln`](../OpenBurnBar.sln).

## Registered seams

| Sub-tree | Seam | Portable core (net8.0/net10.0) | Windows adapter |
|----------|------|--------------------------------|-----------------|
| [`ipc/`](ipc/) + [`ipc-windows/`](ipc-windows/) | app↔daemon named-pipe peer-auth handshake + ConPTY | `OpenBurnBar.Pal.Ipc` (signed-nonce state machine) | `OpenBurnBar.Pal.Ipc.Windows` (hardened pipe + CNG + ConPTY + Job-Object) |
| [`input/`](input/) + [`input-windows/`](input-windows/) | **ViGEm virtual-HID computer-use input path (W5 / R17)** — the non-bypassable-action route | `OpenBurnBar.Pal.Input` (advisory-vs-non-bypassable classification, capability-token gate-before-dispatch, Ed25519 token verify, triple kill-switch, audit) | `OpenBurnBar.Pal.Input.Windows` (ViGEmBus sink + SendInput advisory sink) |

Source files here are ratcheted by the per-tree budget under the `pal` area.
