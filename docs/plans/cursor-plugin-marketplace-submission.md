# OpenBurnBar Cursor Marketplace — Submission Packet

Status: **packet ready, form NOT submitted.** This is the M6 marketplace
submission packet for the OpenBurnBar Cursor plugin. Everything below is
fillable from the locked package and the live thin repo. The final submit
click requires an authenticated operator session (VAL-CROSS-010): never claim
submission without the marketplace response or listing evidence.

## 1. What we are submitting

A single-plugin Cursor Marketplace package whose source of truth is
`plugins/openburnbar/` in an isolated BurnBar worktree, mirrored to the thin
public repo (see §2). Locked manifest identity
(`plugins/openburnbar/.cursor-plugin/plugin.json`):

| Field | Value |
|---|---|
| `name` | `openburnbar` |
| `displayName` | `OpenBurnBar` |
| `version` | `1.0.0` |
| `author` | `OpenBurnBar / Imagine That AI` |
| `homepage` | `https://burnbar.ai` |
| `category` | `integrations` |
| `keywords` | `openburnbar`, `burnbar`, `mcp`, `spend`, `sessions`, `memory`, `resume` |
| `logo` | `assets/logo.svg` (SVG copied from `extensions/openburnbar/media/`) |
| `license` | `AGPL-3.0-only` |
| `repository` | `https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin` |
| `variables` | `required: ["OPENBURNBAR_MCP_ACCESS_TOKEN"]`, no default secret |
| `mcpServers` | `./mcp.json` — HTTP, `https://mcp.burnbar.ai/mcp`, `Authorization: Bearer ${OPENBURNBAR_MCP_ACCESS_TOKEN}` |

## 2. Marketplace git URL (thin repo, not the monorepo)

- **Marketplace git URL:** `https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin`
- Public repo (verified `gh repo view` → `isPrivate: false`), default branch
  `main`, AGPL-3.0-only LICENSE at root, plugin tree at the repo root
  (`.cursor-plugin/plugin.json` at root, `mcp.json`, README, AUTH.md, skills,
  commands, rules, agents, scripts, docs, assets).
- No Swift / Xcode / daemon / monorepo files, no `marketplace.json`.
- The monorepo (`Ajnunezg/BurnBar` or `Imagine-That-Ai/BurnBar`) is **never**
  the marketplace git URL (VAL-DIST-020).

## 3. Locked auth story (what the listing and package state)

- **GitHub-style bearer plugin variable (locked).** Marketplace auth is the
  required variable `OPENBURNBAR_MCP_ACCESS_TOKEN`, sent as
  `Authorization: Bearer ${OPENBURNBAR_MCP_ACCESS_TOKEN}` to the hosted HTTP
  MCP at `https://mcp.burnbar.ai/mcp` (Streamable HTTP, protocol `2025-11-25`).
  This is the Cloud-Agent compatible path; `mcp.json` ships HTTP only.
- **Linear-style OAuth Connect is rejected.** There is no `/oauth/authorize`
  endpoint and no dynamic client registration (`/oauth/register` → 404); the
  AS well-known advertises `grant_types_supported: ["refresh_token"]` only.
  A redirect-based Connect plugin cannot work against the hosted MCP.
- **Stdio shim is out of v1 `mcp.json`.** The optional local
  `openburnbar-mcp-remote` shim (unpublished CLI) is a documented companion
  for Keychain access + 90-day refresh + on-device decrypt; it is not the
  marketplace `mcp.json` server, because a stdio `command` would depend on a
  binary that is not on a normal user PATH and is not on npm.
- **The 15-minute token is not a durable secret.** `OPENBURNBAR_MCP_ACCESS_TOKEN`
  holds a short-lived (~15 min) access token, not a 90-day secret; re-mint it
  when it expires. The durable 90-day refresh stays in Keychain via the
  optional unpublished shim, never in the plugin variable and never in git.

Full locked story: `plugins/openburnbar/AUTH.md` (locked choice, Connect
rejection, shim-vs-HTTP, token lifetime, sealed-field honesty, `/link`
diagnosis, out-of-scope list).

## 4. Submission checklist (verify before submitting)

- [ ] **Name:** manifest `name` is `openburnbar` (kebab-case, exactly).
- [ ] **Display name:** `displayName` is `OpenBurnBar`.
- [ ] **Git URL:** `https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin`
      (thin repo; monorepo is never used).
- [ ] **License:** `AGPL-3.0-only` in `plugin.json` and LICENSE at repo root.
- [ ] **MCP server:** HTTP type, `https://mcp.burnbar.ai/mcp`, no stdio
      `command`/`args`, no clone paths.
- [ ] **Auth variable:** `OPENBURNBAR_MCP_ACCESS_TOKEN` required, described as
      short-lived (~15 min) session credential, no default secret value.
- [ ] **Logo:** `assets/logo.svg` exists in the package (and thin-repo mirror).
- [ ] **Package hygiene:** no `package.json`/lockfile, no venevs/binary trees,
      no secrets in git, no Swift/Xcode/daemon files.
- [ ] **README/AUTH:** install, bearer auth, sealed-field honesty, optional
      shim, plugin-vs-extension distinctions all present.
- [ ] **Validator:** `node plugins/openburnbar/scripts/validate.mjs` exits 0
      against the mirrored tree.

## 5. Optional extra listing: cursor.directory

**Optional** (above the final step): after the marketplace submission, the
same package may be listed on `https://cursor.directory` to improve
discoverability. Reuse the name, description, keywords, and thin-repo URL
from §1–§2. This is a separate, optional operator action; it does not replace
the marketplace publish click and is not required for the submission.

## 6. Form state and remaining operator action

- The marketplace form at https://cursor.com/marketplace/publish was **not
  submitted when this packet was written**. An authenticated operator may
  submit it only after the checklist above passes, then must record the
  response or public listing (VAL-DIST-019 / VAL-CROSS-010).
- Operator evidence that seals the surrounding flow:
  - Local load: `plugins/openburnbar/docs/local-load.md` § 3 keeps the
    **Developer: Reload Window** / Customize slot **awaiting a named human**
    until someone verifies the real Cursor GUI.
  - `/link` grant mint: blocked until the attestation fix is actually deployed
    to production. The current blocker and evidence belong in `AUTH.md` and
    `docs/probe/link-appcheck.md`; do not freeze a PR SHA in this packet.

**Final step:** open https://cursor.com/marketplace/publish in an authenticated
operator session, submit the thin-repo URL, and record the resulting review or
listing evidence.
