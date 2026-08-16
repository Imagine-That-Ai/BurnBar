# Update runbook — OpenBurnBar Cursor Marketplace Plugin

Written post-seal (misc-m8, 2026-08-16) so any future agent can take a
requested change to the OpenBurnBar Cursor Marketplace plugin from idea to
published package without re-deriving the mission's locked decisions. This
file lives inside the plugin package at `plugins/openburnbar/docs/UPDATE.md`;
the thin public plugin repo already carries this same content. The BurnBar
`main` copy at `docs/runbooks/openburnbar-cursor-plugin-update.md` is
**pending PR 2291** (https://github.com/Imagine-That-Ai/BurnBar/pull/2291,
OPEN, REVIEW_REQUIRED, auto-merge armed): it lands on `main` only after a
non-author write user APPROVES. While 2291 is OPEN, this file does not
claim the `main` copy exists.

## Goal

When a user asks to change the OpenBurnBar Cursor Marketplace plugin, make
the change once in the plugin source of truth, prove it with the cheap gate,
land it on the branch that carries the open plugin PR, and re-mirror the thin
public repo so the marketplace package and its install docs agree — without
touching the website-only PR 2286, merging the conflicting PR 2290, or
putting secrets in git.

## Success means

- The change lives under `plugins/openburnbar/` — the source of truth. The
  thin public repo is a generated mirror, never edited directly.
- `node plugins/openburnbar/scripts/validate.mjs` exits 0 from the worktree
  root after the change.
- The commit is on `feat/cursor-plugin-unit` and pushed to origin. While
  PR 2286 is OPEN, `feat/cursor-marketplace-plugin` is **not** pushed.
- `plugins/openburnbar/scripts/publish-mirror.sh` ran, and
  `https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin` carries the
  updated files (including this `docs/UPDATE.md`).
- No secrets: no bearer/refresh/ID tokens, Keychain dumps, or literal
  credentials in any committed file; the plugin variable is declared by name
  only.
- The manifest version is still `1.0.0` — it changes only together with the
  plugin `CHANGELOG.md` and `scripts/validate.mjs` (see “Version lock”).
- Human-gated steps are recorded as slots, not claimed: Reload Window /
  Customize confirm, marketplace Submit, production `/link` confirm after
  PR 2286 deploys.

## Stop when

- The cheap gate is green, the commit is pushed on `feat/cursor-plugin-unit`,
  and the thin repo is re-mirrored.
- PR 2286 is still OPEN at `f90e71ef1` — pushing
  `feat/cursor-marketplace-plugin` would attach every local commit to that
  website-only PR, so it does not happen here.
- PR 2290 (the plugin-unit PR this work rides) is OPEN but CONFLICTING with
  `main` — it is not merged as part of an update.
- Human slots stay human: nothing is submitted to the Cursor marketplace and
  nothing is confirmed on production `/link` by the agent.

## Locked path

| Locked item | Value |
|---|---|
| Source of truth | `plugins/openburnbar/` in the implementation checkout `/Users/dewclaw/BurnBar-cursor-plugin` |
| Cheap gate | `node plugins/openburnbar/scripts/validate.mjs` |
| Push lane while PR 2286 is OPEN | `feat/cursor-plugin-unit` only |
| Re-mirror command | `plugins/openburnbar/scripts/publish-mirror.sh` |
| Marketplace git URL | `https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin` |
| Version | `1.0.0`, locked until `.cursor-plugin/plugin.json` + plugin `CHANGELOG.md` + `scripts/validate.mjs` change together |
| Human slots | Reload Window / Customize (local load), marketplace Submit, production `/link` confirm after 2286 deploys |

## Current PR state — verify before you start

Verify the three PRs before touching anything; the push lane and the
`main`-copy status depend on them:

```bash
gh pr view 2286 -R Imagine-That-Ai/BurnBar --json state,headRefOid,mergeable
gh pr view 2290 -R Imagine-That-Ai/BurnBar --json state,headRefOid,mergeable
gh pr view 2291 -R Imagine-That-Ai/BurnBar --json state,headRefOid,mergeable,autoMergeRequest
```

State as of 2026-08-16:

- PR 2286 (`fix(website): attest completeCliLink with App Check bind + nonce`)
  is OPEN from `feat/cursor-marketplace-plugin` at `f90e71ef1`, website-only,
  MERGEABLE. Deploying it is what unblocks a production `/link` grant confirm.
- PR 2290 (`feat(cursor): OpenBurnBar marketplace plugin`) is OPEN from
  `feat/cursor-plugin-unit` at `c8c6a7363`, CONFLICTING with `main`
  (CHANGELOG.md and website MCP copy at minimum). It is the plugin-unit PR;
  update commits ride it. It is **not** merged here — conflict resolution is
  a merge-time concern, not an update-time one.
- PR 2291 (`docs: OpenBurnBar Cursor plugin update runbook`) is OPEN from
  `docs/openburnbar-plugin-update-runbook` at `e191a1c92`, MERGEABLE but
  REVIEW_REQUIRED, auto-merge armed. It is the vehicle for the `main` copy
  at `docs/runbooks/openburnbar-cursor-plugin-update.md`; that file is on
  `main` only after a non-author write user APPROVES and the queue merges.
  While 2291 is OPEN, nothing here claims the `main` copy already exists.

If 2286 has merged since this was written, the push-lane constraint below
lifts: PR 2290 may then use `feat/cursor-marketplace-plugin`, and this
runbook's locked-path line must be updated in the same commit that changes
the lane.

## Local edit loop

1. Work in `/Users/dewclaw/BurnBar-cursor-plugin` (the only implementation
   checkout), on `feat/cursor-marketplace-plugin`. Never touch
   `/Users/dewclaw/BurnBar` — it is an off-limits dirty tree.
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
5. Never run `make ci`, `xcodebuild`, Gradle, daemon tests, or
   `npm run verify --prefix website`. The plugin has no `package.json` and
   never gains one (a plugin `package.json`/lockfile fails validation and
   forces full CI). Plugin-only diffs classify onto the cheap web lane.
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
- While PR 2286 is OPEN, push **only** `feat/cursor-plugin-unit`:
  1. Commit on the worktree branch (`feat/cursor-marketplace-plugin`).
  2. Fast-forward the local `feat/cursor-plugin-unit` to that commit:
     `git branch -f feat/cursor-plugin-unit <commit>` (or `git merge --ff-only`).
  3. `git push origin feat/cursor-plugin-unit`.
  4. Leave the worktree checked out on `feat/cursor-marketplace-plugin`.
  Pushing `feat/cursor-marketplace-plugin` would add every local commit to
  PR 2286 and break its website-only diff.
- PR 2290 is OPEN but CONFLICTING with `main` — it is the vehicle for this
  work, but it is **not merged here**. Do not resolve its conflicts as part
  of an update, do not rebase/force-push the shared branch, and do not merge
  2286 either.
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
3. Reuses the sibling clone (`/Users/dewclaw/openburnbar-cursor-plugin` by
   default) only when its origin URL **and** any configured `pushurl` match
   the thin repo identity and the working tree is completely clean. Wrong
   origin, wrong pushurl, or a dirty clone exits 1 before any copy.
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

These steps are human-gated; record the slot, do not perform it:

- **Developer: Reload Window / Customize** — local-load confirm that
  Customize → Plugins shows OpenBurnBar. Recorded in
  `plugins/openburnbar/docs/local-load.md` § 3 (awaiting a named human).
- **Marketplace Submit** — the form at
  https://cursor.com/marketplace/publish is submitted only by a human; the
  submission packet (`docs/plans/cursor-plugin-marketplace-submission.md`)
  ends with the exact remaining click.
- **Production `/link` confirm** — after PR 2286 deploys, a human signs in
  at `https://burnbar.ai/link` and confirms a fresh device code; until then
  `AUTH.md` and `docs/probe/link-appcheck.md` name the deploy blocker.

## Keeping this runbook honest

When a locked value changes (PR 2286 merges, PR 2291 merges and the `main`
copy at `docs/runbooks/openburnbar-cursor-plugin-update.md` actually
exists, the version bundle is bumped, the push lane moves), update this
file in the same commit that makes the change, then re-mirror. The runbook
is only useful while it matches the repo's real state.
