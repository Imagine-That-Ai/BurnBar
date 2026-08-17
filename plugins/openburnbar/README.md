# OpenBurnBar — Cursor Plugin

The OpenBurnBar Cursor Plugin connects Cursor agents to the hosted OpenBurnBar
MCP at `https://mcp.burnbar.ai/mcp` for spend and capability diagnostics over
Streamable HTTP (protocol `2025-11-25`). Conversation, knowledge, and
topic-based resume workflows require the local preprocessing/decrypt shim,
which is not bundled in this HTTP-only marketplace plugin.

## Install

Clone the thin public plugin repository, symlink that checkout into Cursor's
local plugin directory, then reload:

```bash
git clone https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin.git
mkdir -p "$HOME/.cursor/plugins/local"
ln -sfn "$(pwd)/openburnbar-cursor-plugin" "$HOME/.cursor/plugins/local/openburnbar"
```

In Cursor, run **Developer: Reload Window**, then open **Settings → Customize →
Plugins** and confirm OpenBurnBar appears. (Marketplace install replaces this
symlink once the plugin is published.)

## Auth — the plugin variable holds a short-lived token

The required variable is `OPENBURNBAR_MCP_ACCESS_TOKEN`, a short-lived
(~15 minute) session credential sent as
`Authorization: Bearer ${OPENBURNBAR_MCP_ACCESS_TOKEN}`. Live setup is
currently blocked until the attested `https://burnbar.ai/link` flow is on
production and BurnBar exposes a safe copy/export action. Today,
`openburnbar mcp login` stores the access token in Keychain and prints only a
success message; it does **not** expose a value that can be pasted into Cursor.
Never put the 90-day refresh token in this variable.

## Sealed-field honesty

The HTTP-only marketplace plugin can call capability, index-status, facet, and
recent-usage tools once authentication is available. It cannot turn a
plaintext topic into the keyed token hashes or cloaked semantic vector required
by hosted conversation and knowledge search. Those calls return
`local_decrypt_shim_required` or require preprocessed inputs. Resume and sealed
body workflows likewise require an explicit opaque identifier plus the local
shim for useful plaintext. Agents stop and name that boundary rather than
inventing results.

## Optional local shim

The local `openburnbar-mcp-remote` shim (unpublished CLI) is an **optional
companion** that provides Keychain-backed access (~15 min) + refresh (~90
days) and on-device decrypt of sealed envelopes. It is **not required in v1
`mcp.json`**: the marketplace package ships only the hosted HTTP server,
because a stdio `command` in `mcp.json` would depend on a binary that is not
on a normal user PATH and is not on npm.

## Plugin vs extension

This is the **Cursor Marketplace plugin candidate** (hosted HTTP MCP,
marketplace publication pending). It is distinct from the **VS Code / Cursor
editor extension** at
`extensions/openburnbar`, which is source-only / load-unpacked, runs the
daemon sidebar, and is **not** listed on VS Marketplace or Open VSX. The
plugin and the extension are separate surfaces; the plugin talks to the
hosted MCP over HTTP and does not bundle the extension.

## Updating the plugin

Maintainers and future agents: read the update runbook at
[`docs/UPDATE.md`](docs/UPDATE.md) before changing this package. It locks the
source of truth, the cheap gate, the push lane while PR 2286 is open, the
thin-repo mirror step, and the `1.0.0` version rule.

## License

AGPL-3.0-only. See [`LICENSE`](LICENSE).
