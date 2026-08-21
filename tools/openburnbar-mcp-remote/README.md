# openburnbar

The OpenBurnBar Node CLI — an MCP stdio shim to the hosted BurnBar MCP,
session resume (`obbresume`), the Pensieve memory hook, and explicit commands
that install or update the notarized macOS app from its public update feed.
One small binary, zero runtime dependencies, honest about what touches the
network.

## Install

Install globally from npm:

```bash
npm i -g openburnbar
```

A global install is what the generated client configs (`openburnbar mcp install <client>`) assume — they reference the `openburnbar` bin by name, which has to resolve on your PATH. For ad-hoc, one-off runs (`--help`, `mcp doctor`, `memory run`) you can skip the install:

```bash
npx -y openburnbar --help
```

`npx` executes the package in an ephemeral cache; use it for manual runs, not as the `command` in a saved MCP client config.

The package ships four bin names, all pointing at the same entry point: `openburnbar` (the name to use), `openburnbar-mcp-remote` (compatibility alias for existing local configs), `obbresume`, and `OBB`.

Requires Node 22+. The package is licensed **AGPL-3.0-only** — see [LICENSE](LICENSE).

`npm i` and `npx` never download the Mac app. There is no `install`,
`postinstall`, or `prepare` hook. The package only places
`OpenBurnBar.app` on disk after you explicitly run `openburnbar app install`
or `openburnbar app update`.

## What this is — and what it isn't

This npm package is the **Node MCP / resume / memory / Mac-app-door CLI**. It
talks to the hosted BurnBar MCP endpoint, resumes sessions, installs the
Pensieve chat-memory hook, and can fetch the current public notarized macOS
DMG when you ask it to.

It is **not** the native daemon operator CLI. The OpenBurnBar Mac app ships its
own Swift CLI, `openburnbar-cli`, which operates the local daemon with exactly
eight commands: `health`, `controller`, `questions`, `followups`, `missions`,
`mission-approve`, `simulator-runs`, `simulator-replay`. That CLI is built from
the app source and is **not published to npm** — if you want it, build the
app. The npm `openburnbar` package never touches the daemon.

## macOS app install and update

```bash
openburnbar app install
openburnbar app update
openburnbar app install --dry-run
```

Both commands:

1. Fetch `https://downloads.burnbar.ai/latest-macos.json`, the same public
   feed used by the notarized desktop updater. The CLI follows whatever
   version and checksum that feed currently advertises; it does not pin a
   marketing version or DMG digest.
2. Download the feed's `downloadUrl` from a first-party host or the official
   `Imagine-That-Ai/BurnBar` GitHub Release.
3. Verify the advertised length, SHA-256, and Sparkle Ed25519 signature
   against the app's pinned `SUPublicEDKey`.
4. Require the Mac to satisfy the feed's `minimumSystemVersion`.
5. Refuse to replace a running app/daemon, a Mac App Store installation, or a
   Homebrew-managed Caskroom installation.
6. Mount the DMG read-only and require the mounted app to have the exact feed
   version, build, and `com.openburnbar.app` bundle identifier.
7. Verify the app code signature and atomically replace
   `/Applications/OpenBurnBar.app`.

`app install` is the first-time path. `app update` refuses when the app is not
installed and is a no-op when the installed build is already current.
`--dry-run` prints the resolved feed plan on any platform and downloads no
DMG. The actual install/update operation is macOS-only.

## Commands

### `openburnbar app install` / `openburnbar app update`

Fetch, verify, and install the current public notarized Mac app. Network
required. No silent download during package installation.

### `openburnbar mcp serve`

Run the stdio JSON-RPC shim. Forwards JSON-RPC to `https://mcp.burnbar.ai/mcp`, decrypts sealed search results locally, and pins `MCP-Protocol-Version` to `2025-11-25` to match the server. Reads the bearer token from the macOS Keychain (or `OPENBURNBAR_MCP_ACCESS_TOKEN` with the explicit insecure-source opt-in). Run `openburnbar mcp login <bearer>` once first.

### `openburnbar mcp install <client>`

Print a client config for `codex`, `claude`, `cursor`, `droid`, `kimi`, `forge`, or `generic` (default). Every snippet invokes `openburnbar mcp serve` — never the old package name — so the `openburnbar` bin must resolve on your PATH: `npm i -g openburnbar` first. Purely local: prints to stdout, makes no network calls.

### `openburnbar mcp doctor`

Run the structured check report: Keychain token presence, `GET https://mcp.burnbar.ai/readyz`, and (when tokened) `tools/list`. Prints one `PASS`/`FAIL` line per check and exits 0 iff all pass, 1 otherwise. This one always phones home.

### `openburnbar mcp login [token]`

With a token argument, stores it as the MCP bearer. Without one, runs the interactive device-link flow: prints a verification URL, waits for browser authorization, stores the token and refresh token, and syncs the vault key. Network required.

### `openburnbar memory <install|run|sync> [sourceSlug] [--transcript <path>]`

The Pensieve memory hook — on-device embed, cloak, and seal plus a local commit queue. **Works on a clean install:** `memory install`. **Needs one extra:** `memory run`/`sync` import Transformers.js lazily from your environment (the shim itself ships zero runtime dependencies), so install the on-device embedder once:

```bash
npm install -g @huggingface/transformers
```

Without it, `memory run`/`sync` fail with an actionable error naming the exact install command.

- `memory install` — installs the chat-memory hook that pipes session-end transcripts into `openburnbar memory run`.
- `memory run` — reads a transcript from `--transcript <path>` or stdin, prepares net-new memory chunks.
- `memory sync` — same pipeline, explicit sync.

All three are local-first and make no calls to mcp.burnbar.ai. Honest caveats:
`memory run`/`sync` spawn your own `claude -p` CLI for extraction (the transcript
is processed by your own Anthropic CLI, billed to your usage), and the embedder
downloads `Xenova/bge-small-en-v1.5` from Hugging Face on first use.

### `openburnbar resume <sessionId>|--query <memory> [--as <harness>] [--model <model>] [--print|--copy|--open|--spawn]`

Resume a past session by UUID, or fuzzy-search your memory by topic. `--copy` puts the briefing on the clipboard, `--open` opens the briefing file, `--spawn` launches the target harness. `obbresume <memory>` and `OBB Resume <memory>` are the same flow with a positional query. Resume calls the hosted MCP — network required.

### `openburnbar proxy [--port 8320] [--host 127.0.0.1] [--allow-local-key] [--token <token>]`

Start a loopback-only OpenAI-compatible gateway on `127.0.0.1:8320`. The fixed local credential is `Bearer local-cliproxy`; `--token` adds another accepted bearer without exposing the service beyond loopback.

- `GET /v1/models` — returns the configured provider/upstream model list, or the GrokD-compatible catalog before a provider is configured.
- `POST /v1/chat/completions` — relays real JSON completions and `stream: true` SSE without fabricating fallback answers.
- Standalone xAI mode — set `XAI_API_KEY`.
- Standalone custom mode — set both `OPENBURNBAR_PROVIDER_BASE_URL` and `OPENBURNBAR_PROVIDER_API_KEY`; remote bases must use HTTPS.
- Forward mode — set `OPENBURNBAR_UPSTREAM=http://127.0.0.1:8317`; only loopback HTTP origins are accepted. `OPENBURNBAR_GATEWAY_TOKEN` is sent upstream when configured.
- No provider configured — `/v1/models` remains available, while chat returns an actionable `503 provider_not_configured`.
- xAI's `x-grok-conv-id` request header is preserved for conversation-level prompt caching. Client bearer tokens and other arbitrary headers are not forwarded upstream.
- Upstream redirects fail closed with `502 unsafe_upstream_redirect`; configure the provider's final API base URL instead.

`openburnbar proxy status [--port 8320]` prints JSON with `listening`, `port`, and `url`, plus the verified PID and mode when the listener matches the proxy's private pid file. `openburnbar proxy stop [--port 8320]` sends `SIGTERM` only after the pid file, private health token, live PID, and listening port agree; it refuses to kill unrelated port owners.

### `openburnbar --help` / `-h` / no args

Prints the usage and exits 0. No network.

## Network honesty

| Command | Network |
|---|---|
| `proxy` | Binds only `127.0.0.1`. Calls xAI when `XAI_API_KEY` is set, the explicit HTTPS custom provider when configured, or the explicit loopback `OPENBURNBAR_UPSTREAM`. |
| `proxy status\|stop` | Loopback/process inspection only; `stop` signals only a pid-file-owned OpenBurnBar proxy. |
| `app install` / `app update` | Yes — `latest-macos.json` plus the feed's DMG URL. Never during `npm i`. |
| `app install --dry-run` | Yes — feed JSON only |
| `mcp serve` | Yes — forwards every message to `https://mcp.burnbar.ai/mcp` |
| `mcp doctor` | Yes — `GET https://mcp.burnbar.ai/readyz` (+ `tools/list` when tokened) |
| `mcp login` | Yes — device-link start/poll against `https://mcp.burnbar.ai` |
| `resume` / `obbresume` | Yes — `tools/call` against `https://mcp.burnbar.ai/mcp` |
| `mcp install` | No — prints local config |
| `memory install` | No — writes the local hook file |
| `memory run\|sync` | No calls to mcp.burnbar.ai — spawns your `claude -p` CLI and downloads the embedder model (`Xenova/bge-small-en-v1.5`) from Hugging Face on first use; also requires `npm install -g @huggingface/transformers` |
| `--help` / `-h` / no args | No — usage text only |

The endpoint is `https://mcp.burnbar.ai/mcp` by default; `OPENBURNBAR_MCP_ENDPOINT` overrides it (loopback hosts allowed for local development, everything else must be https).

## License

AGPL-3.0-only. The full text ships in [LICENSE](LICENSE) and in the npm tarball.

## Releasing (maintainers)

The publish lane is `.github/workflows/npm-publish-openburnbar.yml` in the BurnBar repo. It runs `npm ci` → lint → test → pack, then publishes with OIDC trusted publishing — no tokens in the workflow. For the full update/publish/rollback procedure, see [`docs/NPM_PUBLISH_RUNBOOK.md`](../../docs/NPM_PUBLISH_RUNBOOK.md).

The ordinary `npm test` suite uses injected feed responses and is network
independent. Run `npm run test:live-feed` for the explicit production-feed
integration probe.

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

- **`npm deprecate openburnbar@<bad-version> "reason"`** — the first move for a bad release. Unpublish is time-limited (72 hours after publish, and only with no dependents), so deprecate is the durable lever; then fix forward with a new patch version.
- Delete the `openburnbar-npm-v*` tag or disable the workflow to stop the CI lane.
- The extension's `private: true` stays regardless of any npm rollback.
