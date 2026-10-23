# deepsec

This directory holds the [deepsec](https://www.npmjs.com/package/deepsec)
config for the parent repo. Checked into git so teammates inherit
project context (auth shape, threat model, custom matchers); generated
scan output is gitignored.

Currently configured project: `BurnBar` (target: `..`).

## Setup

1. `nvm use` — selects Node 22+ for deepsec.
2. `pnpm install` — installs deepsec.
3. Add an AI Gateway / Anthropic / OpenAI token to `.env.local`. If
   you already have `claude` or `codex` CLI logged in on this
   machine, you can skip the token for non-sandbox runs (`process` /
   `revalidate` / `triage`); deepsec auto-detects and reuses the
   subscription. See
   `node_modules/deepsec/dist/docs/vercel-setup.md` after install.
4. Open the parent repo in your coding agent (Claude Code, Cursor, …)
   and have it follow `data/BurnBar/SETUP.md` to fill in
   `data/BurnBar/INFO.md`.

## Daily commands

```bash
pnpm deepsec scan
pnpm deepsec process     --concurrency 5
pnpm deepsec revalidate  --concurrency 5                  # cuts FP rate
pnpm deepsec export      --format md-dir --out ./findings
```

`--project-id` is auto-resolved while there's only one project in
`deepsec.config.ts`. Once you've added a second project, pass
`--project-id BurnBar` (or whichever id you want) explicitly.

`scan` is free (regex only). `process` is the AI stage (≈$0.30/file
on Opus by default). Run state goes to `data/BurnBar/`.

## Sandbox checkpoint compatibility

This private repository-scanning workspace uses Deepsec 2.0.12 with the maintained
Vercel Sandbox SDK 2.9.2 and advisory-fixed Zod 4.6.6. The local package patch adapts
Deepsec's sandbox consumers to the SDK's named-sandbox API.

New detached runs save `schemaVersion: 2`,
`sandboxIdentity: "vercel-named-sandbox"`, and separate `sandboxName` and `sessionId`
fields. Status and collection resolve the name without automatic resume, then
verify the saved session ID before accessing a command, downloading, or stopping.

Legacy, unversioned session-ID checkpoints are preserved and refused before any
provider request or file mutation with `DEEPSEC_UNSUPPORTED_LEGACY_CHECKPOINT`.
Keep the original checkpoint. Do not pass its session IDs as sandbox names or
relaunch it as a migration. Recovery needs an independently verified, officially
supported session-ID-to-name mapping; this workspace does not supply one or claim
historical resume compatibility. Existing scanning data is not rewritten.

After `pnpm install --frozen-lockfile`, run `pnpm test:checkpoint-contract` for the
checkpoint tests. They use the patched CLI functions and real SDK with synthetic
credentials and mocked transport; they do not launch a scan or contact a provider.

## Adding another project

To scan another codebase from this same `.deepsec/`:

```bash
pnpm deepsec init-project ../some-other-package   # path relative to .deepsec/
```

Appends an entry to `deepsec.config.ts` and writes
`data/<id>/{INFO.md,SETUP.md,project.json}`. Open the new SETUP.md
in your agent to fill in INFO.md.

## Layout

```
deepsec.config.ts        Project list (one entry per scanned repo)
data/BurnBar/
  INFO.md                Repo context — checked into git, hand-curated
  SETUP.md               Agent setup prompt — checked in, deletable
  project.json           Generated (gitignored)
  files/                 One JSON per scanned source file (gitignored)
  runs/                  Run metadata (gitignored)
  reports/               Generated markdown reports (gitignored)
AGENTS.md                Pointer for coding agents
.env.local               Tokens (gitignored)
```

## Docs

After `pnpm install`:

- Skill: `node_modules/deepsec/SKILL.md`
- Full docs: `node_modules/deepsec/dist/docs/{getting-started,configuration,models,writing-matchers,plugins,architecture,data-layout,vercel-setup,faq}.md`

Or browse on
[GitHub](https://github.com/vercel/deepsec/tree/main/docs).
