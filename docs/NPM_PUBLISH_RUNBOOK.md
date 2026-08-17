# npm Publish Runbook — `openburnbar`

Operational runbook for publishing updates of the npm package **`openburnbar`**
(published from `tools/openburnbar-mcp-remote` in this repo). Read it before
your first publish; follow it for every update after.

## What publishes what

- `tools/openburnbar-mcp-remote` → npm package **`openburnbar`** — unscoped,
  public, `AGPL-3.0-only`, zero runtime dependencies, Node 22+.
- `extensions/openburnbar` (the VS Code extension) is `private: true` and
  **never publishes to npm**. Its `npm publish --dry-run` even exits 0 —
  only a real publish trips the EPRIVATE gate — so do not rely on dry-run as
  a privacy lock.
- The native Swift CLI is `openburnbar-cli`, built from the app source. It is
  **not on npm**. The npm package never touches the daemon.

## Normal update flow (CI lane, preferred)

The publish lane is
[`.github/workflows/npm-publish-openburnbar.yml`](../.github/workflows/npm-publish-openburnbar.yml).
It triggers on pushed tags matching `openburnbar-npm-v*` (distinct from
app-release `v*` tags, so app releases never trigger npm publish), and on
`workflow_dispatch` with a `dry_run` input (default `true`: run
ci/lint/test/pack and stop without publishing).

### Step by step

a. Branch from `origin/main`. Make changes in `tools/openburnbar-mcp-remote`.
   Lint and test green:

   ```bash
   npm run lint --prefix tools/openburnbar-mcp-remote
   npm test --prefix tools/openburnbar-mcp-remote
   ```

b. Bump the version in **both** `package.json` and `package-lock.json`
   (root `version` and `packages[""].version`). `npm version patch --prefix`
   does **not** work with `--prefix`; either edit both files, or:

   ```bash
   cd tools/openburnbar-mcp-remote && npm version patch --no-git-tag-version
   ```

   Run inside the package dir, `npm version` updates both files automatically.

c. Verify the pack from inside the package dir (pack ignores `--prefix`):

   ```bash
   cd tools/openburnbar-mcp-remote && npm pack --dry-run
   ```

   Expect ~28 files: no `src/`, no `*.test.*`, shebang present on
   `lib/index.js` (exec bit 755), vendor wasm under
   `vendor/openburnbar-domain-core-wasm/` included.

d. Open a PR to `main` through the software-factory loop. Use the structured
   large lane (review map, validation matrix, rollback notes) when the diff is
   cross-cutting; the fast lane is fine for mechanical version bumps.

e. After the PR merges, tag the **merge commit on main**. The tag version
   MUST equal `package.json` `version` — the workflow guards this and fails
   on mismatch:

   ```bash
   git fetch origin main
   git tag openburnbar-npm-v<X.Y.Z> <merge-sha>
   git push origin openburnbar-npm-v<X.Y.Z>
   ```

f. The workflow runs `npm ci` → lint → test → `npm pack --dry-run` → tag/version
   guard → `npm publish --access public` with OIDC trusted publishing
   (provenance, no tokens in the workflow; it installs `npm@^11.5.1` itself).
   Watch it:

   ```bash
   gh run list --workflow npm-publish-openburnbar.yml
   ```

g. Verify from the registry and a clean directory:

   ```bash
   npm view openburnbar version            # shows X.Y.Z
   cd "$(mktemp -d)" && npx -y --prefer-online openburnbar@X.Y.Z --help   # exits 0
   ```

   `--prefer-online` is mandatory: the local npx/npm metadata cache can serve
   a stale pre-publish 404 packument.

h. Update [`CHANGELOG.md`](../CHANGELOG.md) under `## [Unreleased]`
   (`### Added` / `### Changed` + bullet) in a follow-up PR.

## Prerequisite: trusted publisher

The CI lane authenticates with OIDC trusted publishing. It only works if the
npm trusted publisher is attached to the package (one-time setup, human with
npm account access):

1. Sign in at npmjs.com and open the `openburnbar` package.
2. **Settings → Trusted Publisher → GitHub Actions**, then enter:
   - Organization: `Imagine-That-Ai`
   - Repository: `BurnBar`
   - Workflow filename: `npm-publish-openburnbar.yml`
3. Save. The workflow's `id-token: write` permission is all the auth it needs.

If this is **not** yet attached — it was a named blocker at first publish —
the tag-triggered publish fails authentication. Do the manual flow below for
that release, then attach the publisher and use the CI lane from then on.

## Manual / emergency publish (host login)

Only when the CI lane is unusable. Publish authentication comes from the host
`npm whoami` login (`alberto8793`).

- The account has 2FA `auth-and-writes` **enabled** (turned on mid-mission
  2026-08-16). A terminal `npm publish` will demand an OTP at an interactive
  TTY — **agents must hand this step to a human**. Alternative: a granular
  access token with "Bypass 2FA" in `~/.npmrc`. Tokens NEVER go into git,
  logs, PR bodies, or handoffs.
- Steps (from inside the package dir — pack/publish ignore `--prefix`):

  ```bash
  cd tools/openburnbar-mcp-remote
  npm publish --dry-run --access public   # inspect the file list
  npm publish --access public             # OTP prompt → human at the TTY
  ```

- Rotate/revoke any bypass-2FA token once the OIDC lane works. A lingering
  token is a credential that outlived its purpose.

## Rollback / containment

- **`npm deprecate openburnbar@X.Y.Z "reason"`** is the first move for a bad
  release. Then publish the fix as `X.Y.(Z+1)`.
- `npm unpublish` only works within npm's time window (72 hours, no
  dependents) and is usually the wrong tool. Deprecate is the durable lever.
- Kill the CI lane: delete the `openburnbar-npm-v*` tag
  (`git push origin :openburnbar-npm-v<X.Y.Z>`) or disable the workflow.
- The extension's `private: true` stays regardless of any npm rollback.

## Failure modes seen in practice

| Symptom | Cause | Fix |
|---|---|---|
| `E403` publishing a new package name | 2FA not enabled on the account | Enable 2FA (auth-and-writes), retry |
| `EOTP` from a non-interactive agent | OTP demanded, no TTY | Hand the publish to a human; do not loop |
| `npm publish --dry-run` exits 0 on a private package | EPRIVATE gate runs only on real publish | Real publish (no network before the gate) or `--workspaces` for the EPRIVATE proof |
| `npm pack --prefix <dir>` packs the wrong thing | `--prefix` silently ignored by pack/publish | `cd` into `tools/openburnbar-mcp-remote` first |
| `npx openburnbar@X.Y.Z` fails right after publish | Stale pre-publish 404 packument in npx/npm cache | Always `npx -y --prefer-online` for registry proofs |
| Tarball `lib/index.js` mode 644, bin not executable | tsc drops the exec bit during prepack build | `prepack` ends with `chmod +x lib/index.js` |
| Compiled `lib/*.test.js` / `*.test.d.ts` ship in tarball | `npm test` compiles tests into `lib/` | `prepack` ends with `rm -f lib/*.test.js lib/*.test.d.ts` |

## Post-publish checklist

- [ ] Registry 200: `curl -sf https://registry.npmjs.org/openburnbar`
      (use the registry endpoint — `www.npmjs.com` serves a Cloudflare 403
      challenge to curl regardless of UA; never use it for checks).
- [ ] `npm view openburnbar dist-tags.latest` equals the version you published.
- [ ] npx proof in a clean dir: `cd "$(mktemp -d)" && npx -y --prefer-online openburnbar@X.Y.Z --help` exits 0.
- [ ] PR body updated with publish evidence (registry 200, dist-tag, npx output, workflow run link).
- [ ] CHANGELOG entry under `## [Unreleased]`.

## Related docs

- Package README and release recipe: [`tools/openburnbar-mcp-remote/README.md`](../tools/openburnbar-mcp-remote/README.md)
- CI lane: [`.github/workflows/npm-publish-openburnbar.yml`](../.github/workflows/npm-publish-openburnbar.yml)
- Hosted MCP service runbook: [`docs/REMOTE_MCP_RUNBOOK.md`](REMOTE_MCP_RUNBOOK.md)
- Hosted MCP architecture: [`docs/HOSTED_REMOTE_MCP.md`](HOSTED_REMOTE_MCP.md)
