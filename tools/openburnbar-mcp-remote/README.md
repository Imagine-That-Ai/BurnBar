# openburnbar

The OpenBurnBar Node CLI — an MCP stdio shim to the hosted BurnBar MCP, session resume (`obbresume`), and the Pensieve memory hook. One small binary, zero runtime dependencies, honest about what touches the network.

## Install

Install globally from npm:

```bash
npm i -g openburnbar
```

Or run it without installing:

```bash
npx -y openburnbar --help
```

The package ships four bin names, all pointing at the same entry point: `openburnbar` (the name to use), `openburnbar-mcp-remote` (compatibility alias for existing local configs), `obbresume`, and `OBB`.

Requires Node 22+. The package is licensed **AGPL-3.0-only** — see [LICENSE](LICENSE).

## What this is — and what it isn't

This npm package is the **Node MCP / resume / memory CLI**. It talks to the hosted BurnBar MCP endpoint, resumes sessions, and installs the Pensieve chat-memory hook.

It is **not** the native daemon operator CLI. The OpenBurnBar Mac app ships its own Swift CLI, `openburnbar-cli`, which operates the local daemon with exactly eight commands: `health`, `controller`, `questions`, `followups`, `missions`, `mission-approve`, `simulator-runs`, `simulator-replay`. That CLI is built from the app source and is **not published to npm** — if you want it, build the app. The npm `openburnbar` package never touches the daemon.

## Commands

### `openburnbar mcp serve`

Run the stdio JSON-RPC shim. Forwards JSON-RPC to `https://mcp.burnbar.ai/mcp`, decrypts sealed search results locally, and pins `MCP-Protocol-Version` to `2025-11-25` to match the server. Reads the bearer token from the macOS Keychain (or `OPENBURNBAR_MCP_ACCESS_TOKEN` with the explicit insecure-source opt-in). Run `openburnbar mcp login <bearer>` once first.

### `openburnbar mcp install <client>`

Print a client config for `codex`, `claude`, `cursor`, `droid`, `kimi`, `forge`, or `generic` (default). Every snippet invokes `openburnbar mcp serve` — never the old package name. Purely local: prints to stdout, makes no network calls.

### `openburnbar mcp doctor`

Run the structured check report: Keychain token presence, `GET https://mcp.burnbar.ai/readyz`, and (when tokened) `tools/list`. Prints one `PASS`/`FAIL` line per check and exits 0 iff all pass, 1 otherwise. This one always phones home.

### `openburnbar mcp login [token]`

With a token argument, stores it as the MCP bearer. Without one, runs the interactive device-link flow: prints a verification URL, waits for browser authorization, stores the token and refresh token, and syncs the vault key. Network required.

### `openburnbar memory <install|run|sync> [sourceSlug] [--transcript <path>]`

The Pensieve memory hook — on-device embed, cloak, and seal plus a local commit queue.

- `memory install` — installs the chat-memory hook that pipes session-end transcripts into `openburnbar memory run`.
- `memory run` — reads a transcript from `--transcript <path>` or stdin, prepares net-new memory chunks.
- `memory sync` — same pipeline, explicit sync.

All three are local-first and make no calls to mcp.burnbar.ai. Honest caveats:
`memory run`/`sync` spawn your own `claude -p` CLI for extraction (the transcript
is processed by your own Anthropic CLI, billed to your usage), and the embedder
downloads `Xenova/bge-small-en-v1.5` from Hugging Face on first use.

### `openburnbar resume <sessionId>|--query <memory> [--as <harness>] [--model <model>] [--print|--copy|--open|--spawn]`

Resume a past session by UUID, or fuzzy-search your memory by topic. `--copy` puts the briefing on the clipboard, `--open` opens the briefing file, `--spawn` launches the target harness. `obbresume <memory>` and `OBB Resume <memory>` are the same flow with a positional query. Resume calls the hosted MCP — network required.

### `openburnbar --help` / `-h` / no args

Prints the one-line usage and exits 0. No network.

## Network honesty

| Command | Network |
|---|---|
| `mcp serve` | Yes — forwards every message to `https://mcp.burnbar.ai/mcp` |
| `mcp doctor` | Yes — `GET https://mcp.burnbar.ai/readyz` (+ `tools/list` when tokened) |
| `mcp login` | Yes — device-link start/poll against `https://mcp.burnbar.ai` |
| `resume` / `obbresume` | Yes — `tools/call` against `https://mcp.burnbar.ai/mcp` |
| `mcp install` | No — prints local config |
| `memory install\|run\|sync` | No calls to mcp.burnbar.ai — may spawn your `claude -p` CLI and download the embedder (`Xenova/bge-small-en-v1.5`) on first use |
| `--help` / `-h` / no args | No — usage text only |

The endpoint is `https://mcp.burnbar.ai/mcp` by default; `OPENBURNBAR_MCP_ENDPOINT` overrides it (loopback hosts allowed for local development, everything else must be https).

## License

AGPL-3.0-only. The full text ships in [LICENSE](LICENSE) and in the npm tarball.

## Releasing (maintainers)

The publish lane is `.github/workflows/npm-publish-openburnbar.yml` in the BurnBar repo. It runs `npm ci` → lint → test → pack, then publishes with OIDC trusted publishing — no tokens in the workflow.

1. Bump `version` in `tools/openburnbar-mcp-remote/package.json` (and `package-lock.json` in lockstep).
2. Commit, then tag: `git tag openburnbar-npm-v<x.y.z>`.
3. Push the tag: `git push origin openburnbar-npm-v<x.y.z>`. The workflow publishes on `push.tags: ['openburnbar-npm-v*']`.
4. Or trigger it manually from the Actions tab with `workflow_dispatch` — the `dry_run` input (default `true`) stops after `npm pack`; set it to `false` to publish.

### Trusted publisher (one-time setup for Alberto)

1. Sign in at npmjs.com as `alberto8793` and open the `openburnbar` package.
2. Go to **Settings → Trusted Publisher**.
3. Choose **GitHub Actions** and enter:
   - Organization: `Imagine-That-Ai`
   - Repository: `BurnBar`
   - Workflow filename: `npm-publish-openburnbar.yml`
4. Save. The workflow's OIDC `id-token: write` permission is all the auth it needs.

**Token rotation:** once OIDC publishing works, revoke any long-lived `NPM_TOKEN` that was ever issued for this package. The workflow carries zero token references by design; a lingering token is a credential that outlived its purpose.

### Rollback / containment

- **`npm deprecate openburnbar@0.1.0 "reason"`** — the first move for a bad release. Unpublish is time-limited (72 hours after publish, and only with no dependents), so deprecate is the durable lever; fix forward as `0.1.1`.
- Delete the `openburnbar-npm-v*` tag or disable the workflow to stop the CI lane.
- The extension's `private: true` stays regardless of any npm rollback.
