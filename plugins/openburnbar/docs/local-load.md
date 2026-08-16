# Local load — symlink, Reload Window, Customize

Captured 2026-08-16. The plugin tree is symlinked into Cursor's local plugin
directory so `Developer: Reload Window` + Customize can pick it up without a
marketplace publish. The Cursor GUI itself is human-gated (see the
confirmation slot below); workers do not drive Cursor.

## 1. Symlink command (identical to README Install)

The command below is the **exact `ln -sfn` string from
[`README.md`](../../README.md) Install**, and it is kept stable for the M4
install doc (`docs/OPENBURNBAR_CURSOR_PLUGIN.md` is still pending, so the
plugin README is the current install reference):

```bash
ln -sfn /Users/dewclaw/BurnBar-cursor-plugin/plugins/openburnbar ~/.cursor/plugins/local/openburnbar
```

Current state on this machine (matches the command exactly):

```
$ ls -l ~/.cursor/plugins/local/openburnbar
lrwxr-xr-x@ 1 dewclaw staff 56 ... openburnbar -> /Users/dewclaw/BurnBar-cursor-plugin/plugins/openburnbar

$ readlink ~/.cursor/plugins/local/openburnbar
/Users/dewclaw/BurnBar-cursor-plugin/plugins/openburnbar
```

Resolved target: `/Users/dewclaw/BurnBar-cursor-plugin/plugins/openburnbar`
(the implementation checkout — **not** `/Users/dewclaw/BurnBar`).

## 2. Install-step parity

The install steps in this doc match the plugin README (`README.md` →
`ln -sfn` → **Developer: Reload Window** → Customize → Plugins) and the
first-visit sequence below. When the M4 install doc lands, it must quote the
same `ln -sfn` command.

## 3. Human confirmation slot — awaiting human (do not claim by workers)

Reload Window and Customize visibility are **human-gated**. This slot is
currently **awaiting a named human** (Alberto / the operator). Workers must
not claim the GUI succeeded.

- [ ] **Developer: Reload Window** run by a named human
- [ ] **Settings → Customize → Plugins** shows **OpenBurnBar**
- [ ] Confirm slot attributed to: _(name + date, filled by the human)_

Until both boxes are checked by a named human, this feature's GUI evidence is
**pending**; the symlink evidence above is complete and machine-verifiable.

## 4. First-visit sequence (README → symlink → Reload → Customize → token → hosted HTTP)

A first-time operator follows, in order:

1. Read the plugin README (`plugins/openburnbar/README.md`) — Install,
   Auth, Sealed-field honesty, Optional local shim, Plugin vs extension.
2. Symlink the worktree plugin:
   `ln -sfn /Users/dewclaw/BurnBar-cursor-plugin/plugins/openburnbar ~/.cursor/plugins/local/openburnbar`
3. Human: **Developer: Reload Window**.
4. Human: **Settings → Customize → Plugins** and confirm **OpenBurnBar**
   appears.
5. Set the required variable `OPENBURNBAR_MCP_ACCESS_TOKEN` via BurnBar
   Settings / `openburnbar mcp login` / Remote MCP
   (`https://burnbar.ai/link`). The value is a **short-lived (~15 min)
   access token, not a durable secret**; re-mint it when it expires.
6. The plugin MCP server is hosted HTTP:
   `type: "http"`, `url: https://mcp.burnbar.ai/mcp`
   (see `../mcp.json`), with the required variable sent as
   `Bearer ${OPENBURNBAR_MCP_ACCESS_TOKEN}` in the `Authorization` header.

Marketplace install replaces the symlink once the plugin is published.

## 5. Authenticated live metadata — named deploy blocker

Per the validation contract, an authenticated hosted-MCP metadata call
(`burnbar_resolve_capabilities` or `burnbar_recent_usage`) is captured only
after PR 1 is on production and a human confirms a fresh device code.
**As of 2026-08-16 PR 1 is OPEN and unmerged**:

- PR: https://github.com/Imagine-That-Ai/BurnBar/pull/2286
  `fix(website): attest completeCliLink with App Check bind + nonce`
  (state: OPEN, not on production)
- Named blocker record: `docs/probe/link-appcheck.md` § 4 “Deploy blocker:
  PR 1 is not on production yet”.

Because that deploy has not happened, there is **no authenticated metadata
transcript here** — this doc records the named blocker instead of a fake
success. No bearer, refresh, or ID tokens appear anywhere in this file or in
`docs/probe/`. Once PR 1 deploys and a human confirms a code, a redacted
metadata transcript lands in `docs/probe/` and this section is updated to
point at it.
