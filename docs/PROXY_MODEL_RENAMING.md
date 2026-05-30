# Proxy Model Renaming

How the OpenBurnBar gateway lets you rename an advertised model so it shows up
under a friendly, human-facing name in the tools that consume the local
OpenAI-compatible gateway (Hermes, PI, Droid, Forge, OpenCode, Codex, Claude
Code, and any generic OpenAI client).

## TL;DR

The **Rename…** action in Settings → Agents → Models (and the embedded panel in
Settings → Agents → CLIs) opens one sheet with two paths:

1. **Display name** (the default, headline field) — a *verbatim rename*. The
   model keeps its wire id and routing; only the human label changes. Emitted
   exactly as typed in `/v1/models` `display_name`.
2. **Advanced → custom wire id** — the power-user path. Mints a new model id
   (an *alias*) that clients call and display directly, while BurnBar still
   routes it to the canonical model.

Pick **Display name** to rename; expand **Advanced** only when a client shows
the raw model id and you need that id itself to change.

## Why two mechanisms?

A model presents to humans in one of two ways depending on the client:

- Some clients read the non-standard `display_name` field from `/v1/models`
  and show it (Hermes, PI; Droid via its `model_display_name` config field).
- Other clients show the OpenAI-standard `id` field and ignore `display_name`
  (Forge and most generic OpenAI tools).

So a single "name" cannot be both free-text-friendly *and* the wire id (wire
ids cannot contain spaces). The two mechanisms cover both worlds:

| Mechanism                  | Changes wire id? | Routing | Shows in Hermes/PI/Droid | Shows in Forge / id-only clients |
| -------------------------- | ---------------- | ------- | ------------------------ | -------------------------------- |
| **Display name** (rename)  | No (stable)      | Unchanged | ✅ verbatim name        | ❌ still shows the model id      |
| **Custom wire id** (alias) | Yes (new id)     | Aliased → base | ✅ alias `display_name` | ✅ shows the new id              |

The display-name override is the right default: it is non-destructive (routing
and saved model selections keep working) and reversible. The alias is the
escape hatch when you specifically need an id-only client to reflect the name.

## What "verbatim" means

Without an override, the gateway *composes* a contextual label, e.g.
`Claude Opus 4.7 · Anthropic · via OpenBurnBar · Reasoning: default`. A display
override is emitted **exactly as typed** — no provider, route, or reasoning
suffixes are appended. `My Work Opus` stays `My Work Opus`.

The gateway flags overridden rows with `display_name_is_custom: true` in
`/v1/models`, which the macOS app uses to render the "renamed" badge and the
"Reset to default" affordance.

## Propagation — when each client updates

- **Live `/v1/models` readers** (Hermes, PI, the Proxy panel itself): update on
  their next catalog refresh — effectively immediately.
- **Synced clients** (Droid, OpenCode): their on-disk config carries the name,
  so it refreshes on the next CLI re-sync — the **Sync to Droid** button, a
  manual re-wire, or the routed-client wiring sentry's periodic sweep / config
  file-watch.
- **Forge / generic id-only clients**: a display-name rename does **not** change
  what they show (they render the id). Use **Advanced → custom wire id** if you
  need the visible name to change there.

## Architecture (for maintainers)

The override is keyed by the canonical model id and stored per provider.

- **Contract** — `BurnBarModelDisplayOverride` and the
  `BurnBarProviderSettings.modelDisplayOverrides` collection, with
  `upsert/remove/displayOverride(forModelID:)/displayName(forModelID:)`
  accessors (`OpenBurnBarCore/.../Contracts/BurnBarProviderContracts.swift`).
- **RPC** — `daemon.provider.model_display_name.set` and `.clear`
  (`BurnBarRPCContracts.swift`), handled in `OpenBurnBarDaemonServer`,
  persisted via `BurnBarConfigStore.setModelDisplayName` / `clearModelDisplayName`.
  Validation is intentionally forgiving: only a non-empty name is required, so
  you can rename a live-discovered model that is not in the static catalog.
- **Single injection point** — `OpenBurnBarLiveModelCatalog` applies the
  override to the base advertised row's `displayName` and sets
  `displayNameIsCustom`. Because the live catalog is the one source feeding
  `/v1/models`, the Proxy UI, the mobile apps, and Droid sync, every surface
  inherits the rename from this one place. Variant rows inherit the flag from
  their base row.
- **Verbatim emission** — `OpenBurnBarHTTPGatewayServer`'s `ModelDescriptor`
  emits `display_name` verbatim (skipping `OpenBurnBarModelDisplayName.compose`)
  when `displayNameIsCustom` is set, and surfaces the flag as
  `display_name_is_custom`.
- **App** — `OpenBurnBarDaemonManager.setProviderModelDisplayName` /
  `clearProviderModelDisplayName` → `OpenBurnBarDaemonSocketClient` →
  daemon RPC. The Proxy panel's `ModelRenameSheet` drives both the display
  override and the Advanced alias path.

## Tests

- `BurnBarModelDisplayOverrideContractTests` (core) — validation, upsert/remove,
  normalization, Codable round-trip + legacy decode.
- `BurnBarModelDisplayOverrideConfigStoreTests` (daemon) — persistence, replace,
  clear, blank rejection, live-only model acceptance.
- `BurnBarModelDisplayOverrideLiveCatalogTests` (daemon) — verbatim override on
  the base row + clear restores the default.
- `OpenBurnBarHTTPGatewayServerTests.testGatewayModelsEmitsVerbatimDisplayNameOverride`
  / `…ComposesDefaultNameWithoutOverride` — the end-to-end `/v1/models` proof.
