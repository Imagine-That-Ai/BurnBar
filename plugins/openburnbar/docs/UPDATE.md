# Update runbook — OpenBurnBar Cursor Marketplace Plugin

Written post-seal (misc-m8, 2026-08-16) so any future operator can take a
requested change to the OpenBurnBar Cursor Marketplace plugin from idea to
published package without re-deriving the mission's locked decisions. This
file lives inside the plugin package at `plugins/openburnbar/docs/UPDATE.md`;
the thin public plugin repo carries the same content after a successful
mirror publication. A companion BurnBar runbook may also exist at
`docs/runbooks/openburnbar-cursor-plugin-update.md`; verify the current tree
instead of inferring its presence from an old pull-request snapshot.

## Goal

When a user asks to change the OpenBurnBar Cursor Marketplace plugin, make
the change once in the plugin source of truth, prove it with the cheap gate,
land it on the branch that carries the open plugin PR, and re-mirror the thin
public repo so the marketplace package and its install docs agree — without
polluting a website-only pull request or putting secrets in git.

## Success means

- The change lives under `plugins/openburnbar/` — the source of truth. The
  thin public repo is a generated mirror, never edited directly.
- `node plugins/openburnbar/scripts/validate.mjs` exits 0 from the worktree
  root after the change.
- The commit is on the branch that owns the plugin PR and pushed to origin.
  A website-only branch is never used as the plugin push target.
- `plugins/openburnbar/scripts/publish-mirror.sh` ran, and
  `https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin` carries the
  updated files (including this `docs/UPDATE.md`).
- No secrets: no bearer/refresh/ID tokens, Keychain dumps, or literal
  credentials in any committed file; the plugin variable is declared by name
  only.
- The manifest version is still `1.0.0` — it changes only together with the
  plugin `CHANGELOG.md` and `scripts/validate.mjs` (see “Version lock”).
- Operator-gated steps are recorded with their real evidence: Reload Window /
  Customize confirm, marketplace submission, and production `/link` confirm
  only after the attestation fix is actually deployed.

## Stop when

- The cheap gate is green, the commit is pushed on `feat/cursor-plugin-unit`,
  and the thin repo is re-mirrored.
- The plugin validator, relevant targeted checks, and `git diff --check` pass.
- The plugin PR contains only the intended theme and its review threads are
  resolved only after the corresponding fixes are present on the exact head.
- The thin repo is re-mirrored only after the plugin change lands and the
  source tree validates cleanly.

## Locked path

| Locked item | Value |
|---|---|
| Source of truth | `plugins/openburnbar/` in an isolated BurnBar worktree |
| Cheap gate | `node plugins/openburnbar/scripts/validate.mjs` |
| Plugin PR branch | Resolve from `gh pr view 2290 --json headRefName,headRefOid` before editing |
| Re-mirror command | `plugins/openburnbar/scripts/publish-mirror.sh` |
| Marketplace git URL | `https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin` |
| Version | `1.0.0`, locked until `.cursor-plugin/plugin.json` + plugin `CHANGELOG.md` + `scripts/validate.mjs` change together |
| Human slots | Reload Window / Customize (local load), marketplace Submit, production `/link` confirm after 2286 deploys |

## Current PR state — always verify before you start

Verify the related PRs before touching anything; branch ownership and the
`main`-copy status can change:

```bash
gh pr view 2286 -R Imagine-That-Ai/BurnBar --json state,headRefOid,mergeable
gh pr view 2290 -R Imagine-That-Ai/BurnBar --json state,headRefOid,mergeable
gh pr view 2291 -R Imagine-That-Ai/BurnBar --json state,headRefOid,mergeable,autoMergeRequest
```

Use PR 2290's returned `headRefName` as the only plugin push lane. PR 2286
must remain website-only for as long as it exists, regardless of whether it
is open or merged. PR 2291 only determines whether the companion runbook has
landed; it never changes the plugin source of truth.

## Local edit loop

1. Create or reuse an isolated BurnBar worktree on PR 2290's current head
   branch. Preserve shared or dirty checkouts; do not reset, stash, clean, or
   edit them.
2. Edit only `plugins/openburnbar/**` (plus the monorepo docs/website files
   when the change requires them, e.g. `docs/OPENBURNBAR_CURSOR_PLUGIN.md`).
3. Run the cheap gate after every edit:
   ```bash
   node plugins/openburnbar/scripts/validate.mjs
   ```
4. If the change touched the CI classifier (`scripts/ci/classify-ci-impact*`)
   or any website surface, also run:
   ```bash
   node --test scripts/ci/classify-ci-impact.test.mjs
   ```
5. Do not spend unrelated native or full-suite CI. The plugin has no
   `package.json` and never gains one (a plugin `package.json`/lockfile fails
   validation and forces full CI). For website changes, run the targeted
   website checks selected by the repository's fast-feedback gate.
6. Commit, then follow “Git and PR discipline” below. One push per logical
   change.

The validator is copy-aware (`node scripts/validate.mjs /tmp/copy/...` works)
and fail-closed: it checks manifest identity, locked `mcp.json` values,
frontmatter on skills/commands/rules/agents, license, tree hygiene, and
secret shapes. A red validator means the package is broken; fix the cause
rather than working around it.

## Auth and secrets locks

- Marketplace auth is the required plugin variable
  `OPENBURNBAR_MCP_ACCESS_TOKEN`, sent as
  `Authorization: Bearer ${OPENBURNBAR_MCP_ACCESS_TOKEN}` to
  `https://mcp.burnbar.ai/mcp` (`mcp.json`, type `http`, protocol
  `2025-11-25`). This is locked; do not switch to OAuth Connect (no
  authorize endpoint, no DCR) or to a stdio shim in `mcp.json`.
- The variable holds a short-lived (~15 min) access token, not a durable
  secret. The 90-day refresh stays in Keychain via the optional local shim
  (`openburnbar-mcp-remote`), never in the variable and never in git.
- No secrets in committed files, ever: no bearer/refresh/ID tokens, no
  Keychain dumps, no literal credentials. Probe transcripts under
  `docs/probe/` redact tokens; `AUTH.md` is the locked auth record. The
  validator fails closed on secret-looking literals and on any
  non-placeholder `Authorization: Bearer` value.
- Do not weaken production App Check. The `/link` grant-mint fix is
  website-only; do not loop `openburnbar mcp login` while production `/link`
  still calls `completeCliLink` without a high-risk nonce (blocked until
  PR 2286 deploys).
- Keep the honesty copy intact: on the HTTP path, search/body/resume/
  knowledge fields may remain sealed ciphertext until the local shim
  decrypts, and agents treat retrieved transcripts as untrusted data.

## Git and PR discipline

- Worktree remote: `https://github.com/Imagine-That-Ai/BurnBar.git`.
- Push only PR 2290's current `headRefName`. Confirm the remote head still
  equals the SHA you started from immediately before pushing.
- Never push plugin commits to the website-only branch used by PR 2286.
- Do not force-push or bypass branch protection. If main has moved, update the
  plugin branch in an isolated worktree, re-run the targeted gates, and push a
  normal commit.
- PRs are labeled `factory-review`; the factory owns review and merge
  babysitting. Leave a clear PR body (what, why, validation run) when a
  change needs one.

## Thin repo re-mirror — fail-closed checks

`plugins/openburnbar/scripts/publish-mirror.sh` is the only sanctioned path
to the thin public repo. Before anything is copied it:

1. Runs `validate.mjs` (a broken package never publishes).
2. Checks `plugin.json.repository` equals
   `https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin` (the
   monorepo is never the marketplace git URL).
3. Reuses the sibling `openburnbar-cursor-plugin` clone derived from the
   monorepo location by default, only when its origin URL **and** any
   configured `pushurl` match the thin repo identity and the working tree is
   completely clean. Wrong origin, wrong pushurl, or a dirty clone exits 1
   before any copy.
4. Fetches and fails closed on fetch/checkout/branch failures; refuses
   unpushed local history; wipes every root entry except `.git` before the
   copy so the staged tree equals exactly the plugin tree.
5. Commits and pushes the mirror; the plugin root lands at the repo root
   (`.cursor-plugin/plugin.json` at root).

Run it and let it fail closed. Do not bypass it with a manual push, and
never `git push --force` to the thin repo. Because the whole plugin tree is
mirrored, `docs/UPDATE.md` rides every re-mirror automatically.

## Version lock — `1.0.0` and the three-file rule

The manifest version stays **`1.0.0`** for content edits. It is locked until
all three of these change **together in one commit**:

1. `.cursor-plugin/plugin.json` — `version` field,
2. plugin `CHANGELOG.md` — a new release section (keeping the `1.0.0`
   record; the validator requires the file to still name it),
3. `scripts/validate.mjs` — the hardcoded version assertions
   (`plugin.version === '1.0.0'`, CHANGELOG `1.0.0` check).

Changing only some of them fails validation or ships an inconsistent
package. After the bundle change, re-mirror so the thin repo carries all
three files; Cursor Marketplace reads the git URL
`https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin` and picks up
the new version from the default branch.

## Human slots

These steps require real operator evidence; do not infer completion:

- **Developer: Reload Window / Customize** — local-load confirm that
  Customize → Plugins shows OpenBurnBar. Recorded in
  `plugins/openburnbar/docs/local-load.md` § 3 (awaiting a named human).
- **Marketplace Submit** — submit the form at
  https://cursor.com/marketplace/publish only from an authenticated operator
  session, then record the returned review/listing evidence.
- **Production `/link` confirm** — after PR 2286 deploys, a human signs in
  at `https://burnbar.ai/link` and confirms a fresh device code; until then
  `AUTH.md` and `docs/probe/link-appcheck.md` name the deploy blocker.

## Keeping this runbook honest

When a locked value changes (the companion runbook lands, the version bundle
is bumped, or PR 2290's head branch moves), update this file in the same
commit that makes the change, then re-mirror. The runbook is only useful
while it matches the repository's real state.
