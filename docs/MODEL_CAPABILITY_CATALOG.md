# Model Capability Catalog

OpenBurnBar keeps model-specific input and output metadata separate from provider routing metadata.
Provider capabilities answer "can this route proxy a request"; model capabilities answer "what can this model accept".

## Source of truth

- Canonical public seed: `website/scripts/rundown-seed/model-capabilities.json`
- Website catalog mirror: `website/scripts/rundown-seed/models.json`
- Static app mirrors: `AgentLens/Resources/openburnbar_models.json` and `OpenBurnBarMobile/Resources/openburnbar_models.json`
- Runtime routing catalog: `OpenBurnBarCore/Sources/OpenBurnBarCore/Resources/catalog.json`

Every model capability row uses `ModelIOCapabilities`:

- `inputModalities` and `outputModalities`
- `contextWindowTokens` and `maxOutputTokens`
- `acceptedInputMimeTypes`
- `supportedParameters`
- `sourceRefs`

## Refresh workflow

Run:

```bash
npm --prefix website run model-capabilities:update
```

The updater refreshes supported OpenRouter rows from `/api/v1/models?output_modalities=all`,
merges them into `model-capabilities.json`, then mirrors the payload into the website seed
and public `data/models.json`.

CI/drift check:

```bash
npm --prefix website run model-capabilities:check
```

When adding a new provider route, only mark a model as accepting images, audio, video, PDFs,
or files after the capability row has a source reference and the route preserves the matching
OpenAI-compatible content part through the gateway.

## Live model discovery

OpenBurnBar automatically discovers available models from each routing provider's live catalog
at runtime, supplementing the static `catalog.json` entries with real-time availability data.

### Discovery strategies

| Provider family | Method | Endpoint / Command | Auth |
|---|---|---|---|
| OpenAI-compatible | `GET /models` | `{baseURL}/models` | `Authorization: Bearer {key}` |
| Ollama Cloud | `GET /search?c=cloud` | `https://ollama.com/search?c=cloud` | None |
| Ollama Local | `GET /api/tags` | `http://localhost:11434/api/tags` | None (local, credential-less) |
| Anthropic | `GET /v1/models` | `{baseURL}/models` | Console: `x-api-key`; OAuth: `Authorization: Bearer` |
| Factory Droid | CLI discovery | `droid exec --help` | `FACTORY_API_KEY` env var |
| Codex CLI picker | CLI discovery | `codex debug models` | Codex CLI local auth |
| Grok CLI picker | CLI/cache discovery | `grok models` + `~/.grok/models_cache.json` | Grok CLI local auth |
| Claude Code picker | Bundled provider catalog | Anthropic catalog rows | Claude Code local auth |
| Antigravity CLI picker | Bundled provider catalog + custom profile row | Google/Gemini catalog rows + `~/.gemini/antigravity-cli/settings.json` custom model | Antigravity CLI local auth |

### Local Ollama discovery details

- The `ollama-local` provider (`local: true` in `catalog.json`, base URL `http://localhost:11434/v1`)
  carries no static models: every model a user has `ollama pull`-ed is discovered live from
  Ollama's canonical `GET http://localhost:11434/api/tags` endpoint, with no `Authorization` header.
  Models suffixed `:cloud`/`-cloud` are filtered out and left to the dedicated Ollama Cloud provider.
- Local providers auto-enable (no credential needed). `BurnBarLiveModelCatalog` advertises the
  discovered models as `route_eligible` whenever the local server responds, and surfaces a
  "start `ollama serve`" error — advertising nothing — when it is down.
- Routing: `BurnBarProviderRouter` resolves a local model as a free, zero-priced passthrough
  (`dynamicDiscoveredProviderModel`) and builds a credential-less route straight to
  `localhost:11434`. To avoid shadowing real providers, a local provider claims only model names
  that no non-local catalog vendor owns — so a request for `gpt-5.5`/`claude-opus-4-8` whose
  vendor isn't configured fails cleanly instead of 404-ing against the local server.
- Picker: advertised local models carry `provider: "ollama-local"`, which the chat model picker
  groups under the existing `HermesModelID.ollama` family (`CLIStreamParsers.hermesFamily`
  matches any provider/model containing `ollama`/`llama`/`qwen`/`mistral`).
- Models ending `:cloud`/`-cloud` served by the local daemon are tagged as Ollama Cloud models;
  everything else is local.

### Anthropic discovery details

- Anthropic's `/v1/models` endpoint returns model objects with `id`, `display_name`, `type`, and capability fields.
- The endpoint paginates with `has_more` / `last_id` / `after_id` cursors (default limit: 20). OpenBurnBar fetches all pages.
- Dated snapshot IDs (e.g. `claude-opus-4-8-20260514`) are normalized to their family ID (`claude-opus-4-8`) so the catalog's matchers and aliases can resolve them.
- Console API keys (`sk-ant-api*`) use the `x-api-key` header; OAuth tokens (`sk-ant-oat*`) use `Authorization: Bearer`.
- Newly discovered Anthropic IDs can route dynamically before `catalog.json`
  is updated. Static catalog rows still provide curated display names, pricing,
  and capability metadata when present.

### Factory Droid discovery details

- Runs `droid exec --help` via the injectable `FactoryDroidProcessRunning` protocol (defaults to `FactoryDroidSystemProcessRunner`).
- Output is parsed by `CLIRuntimeModelCatalog.parseDroidExecHelp`, which extracts model IDs and display names from the `Available Models:` and `Custom Models:` sections.
- Exit code 0 is required for authoritative discovery; non-zero exits produce a non-authoritative result that doesn't block routing.

### CLI picker discovery details

- Codex live picker rows are parsed from `codex debug models`; hidden rows are
  omitted and bundled slug aliases normalize names such as `gpt-5-5` to
  `gpt-5.5`.
- Grok live picker rows are parsed from the `Available models:` section of
  `grok models` and merged with non-hidden, API-supported rows from
  `~/.grok/models_cache.json`.
- Claude Code currently has no reliable model-list command. OpenBurnBar
  catalogs the bundled Anthropic rows for Claude Code `--model` selection so
  new known Claude model IDs are available without profile-only behavior.
- Antigravity currently has no reliable model-list command. OpenBurnBar
  catalogs the bundled Google/Gemini rows for `agy` selection and appends the
  selected profile model only when it is a custom non-catalog model.

### Dated ID normalization

`BurnBarLiveModelCatalog.normalizeAnthropicModelID(_:)` strips trailing `-YYYYMMDD` suffixes from Anthropic model IDs:

```
claude-opus-4-8-20260514 → claude-opus-4-8
claude-sonnet-4-6-20250514 → claude-sonnet-4-6
claude-3-5-sonnet-20241022 → claude-3-5-sonnet
claude-opus-4-8 → claude-opus-4-8 (unchanged)
```

This ensures that live-discovered models match against catalog families regardless of whether Anthropic returns dated or undated IDs.
