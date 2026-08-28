# openburnbar

The OpenBurnBar Node CLI — an MCP stdio shim to the hosted BurnBar MCP,
session resume (`obbresume`), the Pensieve memory hook, explicit commands
that install or update the notarized macOS app from its public update feed,
and a loopback multi-dialect gateway (`openburnbar proxy` on `:8320`).
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

To install the current notarized macOS app in one command (on macOS with Node
22+), run:

```bash
npx -y --prefer-online openburnbar app install
```

That command uses a temporary CLI cache, then explicitly installs the app from
the live signed update feed. For a persistent CLI install, use:

```bash
npm i -g openburnbar && openburnbar app install
```

`npm i -g openburnbar` by itself still installs only the CLI. The app download
is never hidden in an npm lifecycle hook.

The package ships four bin names, all pointing at the same entry point: `openburnbar` (the name to use), `openburnbar-mcp-remote` (compatibility alias for existing local configs), `obbresume`, and `OBB`.

Requires Node 22+. The package is licensed **AGPL-3.0-only** — see [LICENSE](LICENSE).

`npm i` and `npx` never download the Mac app. There is no `install`,
`postinstall`, or `prepare` hook. The package only places
`OpenBurnBar.app` on disk after you explicitly run `openburnbar app install`
or `openburnbar app update`.

## What this is — and what it isn't

This npm package is the **Node MCP / resume / memory / Mac-app-door / loopback
gateway CLI**. It talks to the hosted BurnBar MCP endpoint, resumes sessions,
installs the Pensieve chat-memory hook, can fetch the current public notarized
macOS DMG when you ask it to, and can start **OpenBurnBar Gateway** — a portable
loopback **relay** on `127.0.0.1:8320`.

Two products, two jobs, two marks:

| Surface | Port | Job |
|---|---|---|
| **OpenBurnBar Gateway** (`openburnbar proxy`) | **`:8320`** | Loopback relay for chat, Anthropic Messages, and OpenAI Responses. No burn, no quota, no dialect translation. Distinct connected-nodes mark in the optional macOS tray. |
| **BurnBar Mac daemon** | **`:8317`** | Router: quota, failover, catalog, Hermes, dialect *translation*. Flame mark. |

`openburnbar proxy` is an alternative to vibeproxy / cliproxy. It is not a clone
of either, and it is not the BurnBar daemon. Always use `127.0.0.1`, never
`localhost` — this process binds IPv4 loopback only, and macOS `localhost` often
hits `::1` and is refused.

It is **not** the native daemon operator CLI. The OpenBurnBar Mac app ships its
own Swift CLI, `openburnbar-cli`, which operates the local daemon with exactly
eight commands: `health`, `controller`, `questions`, `followups`, `missions`,
`mission-approve`, `simulator-runs`, `simulator-replay`. That CLI is built from
the app source and is **not published to npm** — if you want it, build the
app. The npm `openburnbar` package never imports daemon Swift.

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

### `openburnbar proxy [--port 8320] [--host 127.0.0.1] [--token <token>] [--tray]`

Start the loopback-only OpenBurnBar Gateway on `127.0.0.1:8320`. The well-known
local credential is `local-cliproxy` (send `Authorization: Bearer local-cliproxy`
or `x-api-key: local-cliproxy`). `--token` / `OPENBURNBAR_GATEWAY_TOKEN` adds
another accepted secret without exposing the service beyond loopback.

| Local path | What it does |
|---|---|
| `GET /health` | Unauthenticated identity. No secrets. |
| `GET /gateway` | Unauthenticated HTML panel. Linux/Windows `--tray` opens this. Lists snippets and the well-known local key. |
| `GET /v1/gateway/panel` | Tray-internal authed JSON (status + copy-paste snippets). Not a client dialect. |
| `GET /v1/models` | Upstream `/v1/models` if configured, else a curated list. Auth required. |
| `POST /v1/chat/completions` | Relay, body unchanged. |
| `POST /v1/messages` | Relay to upstream `/v1/messages`. Forwards `anthropic-version` / `anthropic-beta` (open list); defaults `anthropic-version: 2023-06-01` if missing. Sends the upstream credential as **both** Bearer and `x-api-key`. Query strings are ignored for routing (`POST /v1/messages?beta=true` is still `/v1/messages`). |
| `POST /v1/responses` | Relay to upstream `/v1/responses`, body unchanged. Bearer only. |
| `GET`/`DELETE /v1/responses/:id` | Relay stored-response retrieve/delete. |
| WebSocket `/v1/responses` | Codex Responses WebSocket. Client `response.create` is forwarded as streamed HTTP POST. |

OpenAI-shaped clients use `http://127.0.0.1:8320/v1`. Claude Code and Droid's
`anthropic` adapter use the origin `http://127.0.0.1:8320` (they append
`/v1/messages`).

This process is a **relay, not a translator**. Upstream `404`/`405` on messages
or responses becomes `502 dialect_not_supported` after one upstream call — it
does not retry as chat. Unconfigured POSTs return `503 provider_not_configured`
naming the env vars. Request bodies are capped at **8 MiB** until a real client
413 proves we should raise it. Streaming is HTTP SSE, plus the Responses
WebSocket on `/v1/responses`. SSE pings are forwarded; streams are not
buffered and are not aborted on a wall-clock timeout.

**Standalone:** set `XAI_API_KEY` (xAI chat + responses) or both
`OPENBURNBAR_PROVIDER_BASE_URL` and `OPENBURNBAR_PROVIDER_API_KEY` (remote bases
must be HTTPS). xAI has no `/v1/messages`; Claude Code still needs a
Messages-capable upstream or BurnBar forward.

**Forward to BurnBar** (`OPENBURNBAR_UPSTREAM` wins over standalone). The daemon
authenticates on Bearer / `x-api-key` against **its** gateway token when
configured. Matching tokens are required — `local-cliproxy` is not automatic on
`:8317`:

```bash
export OPENBURNBAR_UPSTREAM=http://127.0.0.1:8317
export OPENBURNBAR_GATEWAY_TOKEN='<same token BurnBar's gateway expects>'
```

`--tray` on macOS compiles the `macos-tray/` sources on demand into
`~/Library/Application Support/OpenBurnBar/gateway-tray/OpenBurnBarGatewayTray.app`
(an `LSUIElement` helper with SF Symbol `point.3.connected.trianglepath`, not
the BurnBar flame), then ad-hoc `codesign`s the binary. Missing `swiftc`
prints `xcode-select --install` and keeps the proxy headless. On Linux and
Windows, `--tray` opens the loopback HTML panel at
`http://127.0.0.1:8320/gateway` (native trays are still later). The helper is a
child of the proxy; SIGTERM on the proxy kills it, but quitting the helper does
not stop the proxy. Install BurnBar uses `openburnbar app install`; Open BurnBar
uses `open -a OpenBurnBar`; Install Podex is an honest coming-soon sheet (no
download URL).

`openburnbar proxy wire <grok|droid|forge|opencode|codex|claude|pi> [--write]`
prints the `:8320` snippet, or with `--write` updates that client's config
using a `# openburnbar:gateway-8320` sentinel so it does not clobber BurnBar
Mac Connect (`:8317`). Cursor BYOK cannot be wired. Dry-run is the default.

`openburnbar proxy status [--port 8320]` prints JSON with `product`,
`listening`, `ready`, both URLs, `localKey`, mode, and commands — never provider
API keys or the pid-file instance token. `openburnbar proxy stop` sends SIGTERM
only after the pid file, private health token, live PID, and listening port
agree.

#### Client matrix (copy-paste; the tray never writes dotfiles)

| Client | Wire | Notes |
|---|---|---|
| Grok Build / SDK | chat | `~/.grok/config.toml` `[model.openburnbar]` with `base_url = "http://127.0.0.1:8320/v1"` and `env_key = "OPENBURNBAR_GATEWAY_TOKEN"`. Do **not** steal `XAI_API_KEY` from the proxy process. |
| Droid generic | chat | `customModels[]` `provider: "generic-chat-completion-api"`, `baseUrl: ".../v1"`. |
| Droid Claude | messages | `provider: "anthropic"`, `baseUrl: "http://127.0.0.1:8320"` (no `/v1`). Needs Messages-capable upstream. |
| Droid OpenAI | Responses | `provider: "openai"`, `baseUrl: ".../v1"`. Works standalone xAI via `/v1/responses`. |
| Forge | chat | `[[providers]]` `url = ".../v1/chat/completions"`, `models = ".../v1/models"`, `response_type = "OpenAI"`, `api_key_var = "OPENBURNBAR_GATEWAY_TOKEN"`. Matches Mac wiring keys. |
| OpenCode | chat | `provider.openburnbar.npm = "@ai-sdk/openai-compatible"`, `options.baseURL = ".../v1"`. Some v2 builds also read `settings.baseURL`; that is a pointer, not a second source of truth. |
| Codex CLI | Responses HTTP + WebSocket | `[model_providers.openburnbar]` `wire_api = "responses"`, `requires_openai_auth = false`, **`supports_websockets = false`** (HTTP SSE default). The gateway also accepts the Responses WebSocket on `/v1/responses`, so a Codex build that ignores the flag still works. `GET`/`DELETE /v1/responses/:id` are relayed. |
| Claude Code | messages | `ANTHROPIC_BASE_URL=http://127.0.0.1:8320`, pin `ANTHROPIC_MODEL`. No discovery flag (`CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` is a BurnBar `:8317` catalog feature). |
| Pi coding agent | client | Point `~/.pi/agent/models.json` at `http://127.0.0.1:8320/v1`. BurnBar's Pi runtime on `:8765` is not an OpenAI gateway. |
| Cursor BYOK | — | **No.** Requests originate at `api2.cursor.sh`; `127.0.0.1` is that backend's loopback. |

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
| `proxy` | Binds only `127.0.0.1`. Calls xAI when `XAI_API_KEY` is set, the explicit HTTPS custom provider when configured, or the explicit loopback `OPENBURNBAR_UPSTREAM`. Relays HTTP SSE and the Responses WebSocket. |
| `proxy wire|unwire` | Local config files only. Dry-run unless `--write`. |
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
