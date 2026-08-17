# OpenBurnBar Cursor Marketplace Plugin

The **Cursor Marketplace plugin candidate** (package: `plugins/openburnbar/`) connects
Cursor agents — desktop **Customize** and **Cloud Agents** — to the hosted
OpenBurnBar MCP at `https://mcp.burnbar.ai/mcp` over Streamable HTTP
(protocol `2025-11-25`). The HTTP-only package supports spend and capability
diagnostics. Conversation, knowledge, and topic-based resume workflows require
the optional local preprocessing/decrypt shim. The plugin's
source of truth is `plugins/openburnbar/`; the marketplace git URL is
`https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin` (thin public
repo, not the BurnBar monorepo).

## 1 · Install / local load

**Local load (before marketplace publish).** Clone and symlink the thin public
repository root, then reload the window:

```bash
git clone https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin.git
mkdir -p "$HOME/.cursor/plugins/local"
ln -sfn "$(pwd)/openburnbar-cursor-plugin" "$HOME/.cursor/plugins/local/openburnbar"
```

In Cursor run **Developer: Reload Window**, then open **Settings → Customize →
Plugins** and confirm **OpenBurnBar** appears. The same sequence is recorded in
[`plugins/openburnbar/docs/local-load.md`](../plugins/openburnbar/docs/local-load.md).

**Marketplace install (after publish).** Install from the Cursor Marketplace;
the thin public repo `Imagine-That-Ai/openburnbar-cursor-plugin` (not the
monorepo) is the marketplace git URL. The plugin's `mcp.json` ships the hosted
HTTP server only — no stdio command, no clone path, no `package.json` in the
plugin tree.

**Requirement:** BurnBar Cloud Pro/Ultra for hosted Remote MCP access.

## 2 · Auth — the plugin variable holds a short-lived token

The required plugin variable is `OPENBURNBAR_MCP_ACCESS_TOKEN`, a
**short-lived (~15 minute) access token**. Live setup is blocked until the
attested `/link` flow is deployed and BurnBar exposes a safe copy/export
action. `openburnbar mcp login` currently stores the token in Keychain and
does not print a value to paste. Never put the 90-day refresh token in Cursor.
When the copy path exists, the plugin sends the access token as
`Authorization: Bearer ${OPENBURNBAR_MCP_ACCESS_TOKEN}`.

The locked auth choice is the GitHub-style bearer variable: Linear-style
OAuth Connect is impossible (no `/oauth/authorize`, no dynamic client
registration) and the stdio shim is not the v1 marketplace `mcp.json` server.
See [`plugins/openburnbar/AUTH.md`](../plugins/openburnbar/AUTH.md) for the
full decision record and live probe transcripts.

## 3 · Sealed-field honesty

The hosted conversation search handler needs vault-key-derived `tokenHashes`
or `semanticHashes`; knowledge search needs a cloaked 384-element
`queryVector`. The HTTP-only marketplace package cannot derive those values.
Agents stop and name the local preprocessing/decrypt-shim requirement rather
than sending plaintext or treating an empty shim-required result as a real
search.

Default grant scopes are `search:read`, `conversation:read`, `usage:read`,
`index:status` — **not** `knowledge:read` / `code:read`. The knowledge tools
(`burnbar_search_knowledge`, `burnbar_get_knowledge_document`) are listed but
may be unavailable until the grant includes `knowledge:read`; agents call
`burnbar_resolve_capabilities` before assuming the tool set. Flag-gated code
tools (`burnbar_search_code`, `burnbar_get_code_document`) are not advertised
as available.

## 4 · Three Cursor surfaces — extension, personal MCP, marketplace plugin

Cursor has **three distinct OpenBurnBar surfaces**; they are not the same
thing:

1. **VS Code / Cursor editor extension** (`extensions/openburnbar`) — the
   activity-bar sidebar backed by the local daemon over a UNIX socket.
   **Source-only**: build locally and load unpacked; it has **no** VS
   Marketplace / Open VSX listing and no signed VSIX.
2. **Personal / operator MCP** — the adjacent tooling: the local stdio shim
   `openburnbar-mcp-remote` (bridges stdio-only clients to the hosted
   endpoint, decrypts on-device) or the local SQLite MCP under
   `tools/openburnbar-mcp`. This is operator tooling, not the marketplace
   package.
3. **Cursor Marketplace plugin candidate** (this document,
   `plugins/openburnbar/`) — a pending listing that talks to hosted HTTP
   `https://mcp.burnbar.ai/mcp` with the bearer variable. This is the new
   marketplace listing once published; it does **not** replace the editor extension.

## 5 · Optional local shim

The local `openburnbar-mcp-remote` shim (unpublished CLI) is an **optional
companion**: Keychain-backed access (~15 min) + refresh (~90 days) and
on-device decrypt of sealed envelopes. It is **not required in v1
`mcp.json`** — the marketplace package ships only the hosted HTTP server,
because a stdio `command` in `mcp.json` would depend on a binary that is not
on a normal user PATH and is not on npm. The 90-day refresh stays in
Keychain via the shim / `openburnbar mcp login` operator path, never in the
Cursor plugin variable.

Cloud Agents use the same HTTP + bearer path as desktop Customize; no
user-facing surface tells Cloud Agents to use the stdio shim.

## Cheap CI gate

The plugin's structural validator is the cheap local and CI gate — no
`package.json`, no `npm ci`:

```bash
node plugins/openburnbar/scripts/validate.mjs
```

CI runs it in the dedicated `plugin-fast` job of
`.github/workflows/fast-feedback.yml` whenever the classifier maps a diff to
the web lane. The classifier routes `plugins/openburnbar/**` to that cheap web
lane; teaching the classifier stays a full-CI change by policy.

## Update runbook

Future agents and maintainers who change this plugin must follow the
in-package update runbook
[`plugins/openburnbar/docs/UPDATE.md`](../plugins/openburnbar/docs/UPDATE.md):
it locks the source of truth, the cheap gate, the push lane while PR 2286 is
open, the thin-repo mirror step, the marketplace git URL, and the `1.0.0`
version rule.

## License

AGPL-3.0-only. See [`plugins/openburnbar/LICENSE`](../plugins/openburnbar/LICENSE).
