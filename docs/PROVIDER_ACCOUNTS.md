# Provider Accounts

Provider accounts are OpenBurnBar's first-class billing and quota identities. They
are separate from the signed-in OpenBurnBar/Firebase user and separate from local
launcher profiles in the account switcher.

## Concepts

- **OpenBurnBar account:** the Firebase user that owns cloud-synced data.
- **Provider account:** one credential or session for a provider such as OpenAI,
  MiniMax, Z.ai, Factory, or Cursor. A provider can have multiple labeled
  accounts like `Work`, `Personal`, or `Client`.
- **Switcher profile:** a local browser or CLI launch identity. It may be linked
  to a provider account, but it is not itself the billing/quota account.

## Storage Model

Public provider account metadata is written to:

```text
users/{uid}/provider_accounts/{accountID}
```

Those documents contain labels, provider IDs, status, redacted credential labels,
source device IDs, and refresh timestamps. They must not contain raw credentials
or server secret references.

Cloud-refreshable credentials are written through Cloud Functions and stored in
Secret Manager. The Firestore mapping from account ID to Secret Manager version
lives outside `users/{uid}` in a server-private collection. Mac-local credentials
stay in the macOS Keychain or daemon credential slots; only non-secret metadata
and quota snapshots sync to mobile devices.

`connectProviderAccount` only accepts credential methods that the server-side
adapter can validate and refresh from Cloud Functions. Browser-login, local
runtime, and daemon-managed methods must use the Mac app, hosted quota sync, or
self-hosted quota sync flow so local/session secrets are not promoted into
cloud-refreshable server credentials by stale clients.

## Refresh Behavior

- **Cloud-refreshable accounts:** refresh from Cloud Functions on any signed-in
  Apple device. OpenAI usage refresh requires an organization admin API key.
- **Local-only accounts:** metadata and snapshots sync from the Mac, but refresh
  happens only on the owning Mac.
- **Device Keychain accounts:** daemon-managed slots appear as provider accounts
  with their labels and status, while the credential remains on that Mac.
  Catalog-only routing providers such as DeepSeek, Alibaba/Qwen, Meta, Mistral,
  and Cohere use the same daemon-slot projection even when they have no
  `AgentProvider` enum case. (xAI/Grok is now a first-class `AgentProvider.xAI`
  with its own quota adapter — see below.)

Quota snapshots use schema version 2 and include `providerID`, `accountID`,
`accountLabel`, `accountStorageScope`, and `sourceID`. Provider-level views keep
aggregates, while detail views preserve per-account snapshots and unattributed
legacy usage.

## xAI / Grok

Grok is a full-service quota provider (`AgentProvider.xAI`, catalog id `xai`).
It supports a consumer tier and a developer tier, selected via the **plan
picker** in the quota popover, command center, and macOS plan wizard.

### Connect via xAI Management Key (GrokBuild — exact credits)

1. Open the [xAI Console → Team API Keys](https://console.x.ai/team/api-keys).
2. Generate a **Management Key** (prefix `xai-mgmt-…`). This is separate from
   the inference key the proxy uses to serve requests.
3. Paste it into the Grok card's "Management Key" field and pick the
   **GrokBuild** tier.

The adapter then reports the exact prepaid credit balance from
`GET /v1/billing/teams/{team_id}/prepaid/balance` (xAI returns a negative
`total.val` in USD cents when credit is unspent; the adapter inverts it) plus
rolling 24h / 7d / 30d spend from `POST /v1/billing/teams/{team_id}/usage`. The
team id is auto-discovered via `GET /v1/teams` and cached.

### SuperGrok remaining prompts (estimated — no vendor login)

SuperGrok Lite / SuperGrok / SuperGrok Heavy have no public consumer remaining-quota
API, and OpenBurnBar does not offer a SuperGrok OAuth or grok.com session capture.
Pick the matching tier in the quota card; the rolling cap is community-estimated
(Lite 30 / SuperGrok 100 / Heavy 400 prompts per 2h) and the snapshot is flagged
as estimated. Add an `xai-…` inference key so the Mac proxy can route Grok
traffic, which populates the pacing log
(`~/Library/Application Support/OpenBurnBar/xai/superGrok-events.jsonl`).
This is not a vendor login.

See [grok.com/plans](https://grok.com/plans) for current tier pricing.

### Grok Build CLI login (`~/.grok/auth.json`)

`grok login` writes `~/.grok/auth.json` (OIDC session or `xai::api_key`).
OpenBurnBar detects that file the same way it detects Codex `auth.json`: presence
of a non-empty `key` field, plus a safe email label when the CLI stored one.
A bare `~/.grok` folder or `sessions/` tree is not a login. CLI auth is
historical session usage via `GrokParser`, not SuperGrok remaining quota and not
GrokBuild prepaid credits. Connections → Grok Build only routes the CLI through
the local gateway.

### Grok Build CLI (Mac Switcher + gateway wiring)

Grok Build is the **CLI product surface** for xAI on Mac. OpenBurnBar keeps a single
vendor identity (`AgentProvider.xAI`, catalog id `xai`) and adds a Switcher CLI profile
(`SwitcherCLIProfileType.grok`, UI label **Grok Build**).

1. Install the official `grok` CLI and sign in (or set `XAI_API_KEY`).
2. In **Settings → Connections**, connect **Grok Build**. OpenBurnBar writes an
   `[model.openburnbar]` block to `~/.grok/config.toml` pointing at the local
   OpenBurnBar HTTP gateway (`127.0.0.1:8642` by default).
3. Session usage is parsed from `~/.grok/sessions/<encoded-cwd>/<uuid>/` via
   `GrokParser` (`signals.json` → `contextTokensUsed`, with `chat_history.jsonl`
   for conversations).
4. Routed xAI gateway traffic emits SuperGrok pacing events; GrokBuild prepaid balance
   ≤ $5 maps to routing **pressure**, ≤ $0 to **exhausted**. Live catalog marks xAI
   slots below 20% remaining as **cooling down** and excludes them from proactive routing.

CLI sessions sync to Firestore as **archive-only** (`CLIAgentRuntime.grok`); native
resume (`grok -r`) is not yet in `native_eligible`.

### Manual Mac check (three xAI lanes)

This is vendor-meter setup, not BurnBar Firebase sign-in. Do not use Settings → Account.

**Lane 1 — GrokBuild (exact credits)**

1. Open [console.x.ai/team/api-keys](https://console.x.ai/team/api-keys) and create a Management Key (`xai-mgmt-…`). Do not paste an `xai-…` inference key here.
2. BurnBar menu bar → Quotas (or Settings → Quotas) → xAI card → expand.
3. Confirm the card shows three lanes: **GrokBuild credits**, **SuperGrok (estimated)**, **Grok CLI**.
4. Paste the management key into GrokBuild → pick **GrokBuild** in the plan picker → **Save & refresh**.
5. Expect prepaid credit balance plus 24h / 7d / 30d spend. A rejected key must say the key was rejected, not “quota connected.”
6. Settings → Connections → **Grok Build** is still “route the CLI.” Connecting it does not refresh GrokBuild meters.

**Lane 2 — Grok CLI (`~/.grok/auth.json`)**

1. Install the official `grok` CLI. Run `grok login` in Terminal (or Account Switcher → Grok Build → Add Account).
2. Confirm `~/.grok/auth.json` exists and has a non-empty `key` under an `https://auth.x.ai…` or `xai::api_key` entry. An empty `~/.grok` folder or `sessions/` tree alone is not a login.
3. Re-open Quotas → xAI. The Grok CLI lane should show the email from `auth.json` (or “Grok CLI API key” / `XAI_API_KEY`).
4. That lane is presence-only. It does not fill SuperGrok remaining prompts or GrokBuild credits.

**Lane 3 — SuperGrok (estimated, no vendor login)**

1. Quotas → xAI → SuperGrok lane. There is no Connect / Sign in / WKWebView.
2. Pick SuperGrok Lite / SuperGrok / SuperGrok Heavy → **Save & refresh**.
3. Expect an estimated 2-hour prompt window (30 / 100 / 400) flagged estimated. Status copy must say remaining-quota is estimated and that xAI has no SuperGrok remaining-quota API.
4. Routing still needs an `xai-…` inference key. Routed Grok traffic fills `~/Library/Application Support/OpenBurnBar/xai/superGrok-events.jsonl`.

Inference key ≠ meter: an `xai-…` key only routes. `xai-mgmt-…` only meters GrokBuild. CLI `auth.json` only proves `grok login`.

## Google Gemini

Google is catalog provider `google` (alias `gemini`, quota adapter `AgentProvider.geminiCLI`).
It is **not** Firebase “Sign in to BurnBar with Google.”

| Lane | What you connect | Meters |
|---|---|---|
| Gemini CLI sessions | Detect `~/.gemini` on the Mac | Used tokens for the last 24 hours and 7 days from session logs. Remaining quota is unavailable. |
| Antigravity | Local Antigravity profile | Estimated 5-hour coding windows from `AntigravityQuotaAdapter`. |
| AI Studio API key (`AIza…`) | Daemon slot | Key saved only. Does **not** unlock remaining RPD/RPM/TPM. |
| Google AI Pro / Gemini app (including Verizon) | Label only | Remaining app quota is **not published**. BurnBar will not invent a percentage. |

Cloud Functions does not refresh Google accounts. Snapshots stay Mac-local, like Claude and Antigravity.

See [PROVIDERS.md](PROVIDERS.md) for the adapter contract.

## Endpoint profiles

Some providers expose multiple inference clusters or billing lanes behind
different API key prefixes. OpenBurnBar models these as **endpoint profiles**
(`endpointProfileID` on provider accounts and daemon credential slots).

| Field | Purpose |
|---|---|
| `endpointProfileID` | Stable profile id (e.g. `mimo.token-plan.sgp`) |
| `region` | Cluster selector (`cn`, `sgp`, `ams`, `global`) |
| `authMethodID` | Connect wizard lane (`mimo-token-plan`, `mimo-payg`, …) |
| `tokenPlanTier` / `tokenPlanBillingCycle` | Quota fallback when vendor remains are unavailable |

Resolution order:

1. Explicit `endpointProfileID` on the account or slot (connect wizard / mobile payload)
2. Key-prefix inference (`tp-` vs `sk-` for MiMo)
3. Explicit `region` for Token Plan keys

The daemon router uses `ProviderRouteEndpointResolver` so failover stays within
the same profile. Quota adapters read the profile’s `quotaRemainsURL` when present.

Profiles are registered in `OpenBurnBarCore` (`ProviderEndpointProfileRegistry`).

### MiniMax

MiniMax is catalog provider `minimax` with two endpoint profiles:

| Profile ID | Key prefix | Inference base | Quota remains |
|---|---|---|---|
| `minimax.token-plan` | `sk-cp-…` | `https://api.minimax.io/v1` | `https://www.minimax.io/v1/token_plan/remains` (Coding Plan fallback: `…/api/openplatform/coding_plan/remains`) |
| `minimax.payg` | `sk-api-…` | `https://api.minimax.io/v1` | Routing + validation only |

The daemon router and macOS quota adapter resolve profiles through
`ProviderRouteEndpointResolver`. Cloud Functions try Token Plan remains first,
then fall back to the Coding Plan endpoint for legacy `sk-cp-…` keys.

## Xiaomi MiMo

MiMo is catalog provider `mimo` (`AgentProvider.mimo`, display **Xiaomi MiMo**).

| Lane | Key prefix | Inference base | Quota |
|---|---|---|---|
| Token Plan | `tp-…` | `https://token-plan-{cn,sgp,ams}.xiaomimimo.com/v1` | L1 `GET …/token_plan/remains`; L2 tier cap ledger; L3 unavailable |
| Pay-as-you-go | `sk-…` | `https://api.xiaomimimo.com/v1` | Routing + validation only (no balance API) |

### Connect (Mac daemon slot)

1. Open **Settings → Providers → MiMo** (plan wizard).
2. Choose **Token Plan** or **Pay-as-you-go**.
3. For Token Plan, pick cluster (`cn` / `sgp` / `ams`) and subscription tier.
4. Paste the API key. Token Plan saves `endpointProfileID`, `region`, tier, and billing cycle on the slot.

Global (`region: global`) is rejected for Token Plan connect — pick a regional cluster.

### Connect (mobile cloud account)

iOS and Android call `connectProviderAccount` with the same metadata fields as
Mac slots. Hosted OAuth is not used for MiMo (API key only).

### Quota settings sync

Mac quota command center mirrors Token Plan region / tier / billing cycle into
`QuotaSettings` so `MimoQuotaAdapter` can fall back to tier caps when the vendor
remains endpoint returns no buckets.

## OpenCode Go

OpenCode is catalog provider `opencode` (`AgentProvider.openCode`, aliases
`opencode-go`, `open-code`, `open code go`). **Multiple OpenCode Go
subscriptions can be connected side by side**, the same as Ollama, Codex, and
Anthropic.

### Connect one account per subscription

1. Open **Settings → Connections → OpenCode** and choose **OpenCode auth.json**.
2. Either import the currently signed-in `~/.local/share/opencode/auth.json`, or
   paste another subscription's `opencode-go` entry, its full `auth.json`, or the
   bare route key.
3. Give the account a label (`Work`, `Personal`, `Client`) and save. Repeat per
   subscription.

Each connection becomes its own daemon credential slot, and therefore its own
`ProviderAccountDoc` with independent routing, failover, cooldown, and enable or
disable state. `OpenBurnBarProviderCredentialNormalizer` extracts the route key
from whichever of the three paste shapes was used.

Credentials are stored **per slot**
(`provider.opencode.slot.<slotID>.apiKey`). OpenCode previously also mirrored
each credential into the shared `opencode_auth_json` app-keychain account; that
account is a singleton, so connecting a second subscription overwrote the
first one's secret and pinned the provider-level lane to whichever account was
saved last. The mirror is no longer written. Installs that already have a
mirrored value keep working — `opencode_auth_json` is still read as a legacy
fallback, it is just never written again.

### Quota is device-wide, spend is per account

OpenCode Go exposes no hosted per-account quota API. `OpenCodeQuotaAdapter`
derives plan pressure from this machine's `opencode.db` spend plus
`opencode stats` CLI history, and both cover every subscription signed in on the
device. Three subscriptions therefore share **one** device-wide estimate, which
OpenBurnBar reports once at provider level (labelled *This Mac · all
subscriptions*) instead of rendering three identical account cards and
triple-counting one machine in the cumulative merge. This is the same hold-out
that keeps organization-scoped OpenAI provider-level; the shared list is
`QuotaCapableProviderMap.providerLevelOnlyQuotaProviders`.

Per-subscription **spend** is attributed wherever BurnBar sees the credential:
traffic routed through the OpenBurnBar gateway carries its credential slot, so
each subscription's burn lands on its own account (see
[Usage Attribution](#usage-attribution-which-account-is-burning)).

OpenCode CLI traffic that bypasses the gateway is the one gap, and it is a
deliberate one. Unlike Cursor, Codex, and Claude Code — whose local state files
expose an email or account id — OpenCode's `auth.json` carries only the
`opencode-go` route key for the signed-in subscription. Identifying which
subscription produced a locally parsed session would mean fingerprinting that
key against each daemon slot's stored secret, which would put credential reads
into the log-parser path. OpenBurnBar does not do that: locally parsed OpenCode
sessions stay unattributed at provider level. Route OpenCode through the
BurnBar gateway when you need per-subscription spend.

## Usage Attribution (which account is burning)

Provider accounts answer "which seat is authorized"; usage attribution answers
"which seat spent the tokens". Every `token_usage` row carries
`providerAccountID`, `providerAccountLabel`, and `providerAccountSource`, so a
user with three Cursor seats or three OpenAI accounts can see the burn split per
account instead of one merged provider total.

Rows get their account from one of three sources:

| Source | How the account is determined |
|---|---|
| Local tool sign-in | A resolver reads the tool's own signed-in identity, and the parsed session is matched to whichever account was signed in during that session's time window. |
| Daemon-routed traffic | The router already picked a credential slot; that slot rides `BurnBarUsageEvent` through the ledger into `token_usage`. |
| Billing APIs | The account is whatever credential the pull authenticated with. |

### Local identity resolvers

`ProviderAccountIdentityResolving` implementations read only non-secret identity
metadata from each tool's own state, never OpenBurnBar credentials and never the
Keychain:

| Provider | Source | Field |
|---|---|---|
| Cursor | `state.vscdb` (`ItemTable`) | `cursorAuth/cachedEmail` |
| Codex | `$CODEX_HOME/auth.json` | `tokens.account_id` + the `email` claim of `id_token` |
| Claude Code | `.claude.json` (honors `CLAUDE_CONFIG_DIR`) | `oauthAccount.accountUuid` / `.emailAddress` |

The Cursor resolver deliberately does not read `cursorAuth/accessToken`, and the
Claude resolver keeps the documented posture of never reading the Claude
Keychain item or `.credentials.json`.

### The identity timeline

Local tools record usage without naming the account, so attribution is
time-based. `ProviderAccountIdentityTimelineStore` journals which identity was
signed in for each provider over time
(`provider_account_identity_timeline.json`, device-local, never synced). A
parsed session is attributed when its `[startTime, endTime]` interval falls
inside exactly one identity window; a session spanning an account switch stays
unattributed rather than guessing.

An identity holds from its first observation until a *different* identity is
observed, so gaps between refresh ticks do not un-attribute usage.

Usage recorded **before** the first observation stays unattributed on purpose.
Backdating the first-seen identity across pre-existing history would assign
every past session to whichever account happened to be signed in when
attribution first ran — on the multi-seat device this feature exists for, that
guess is wrong often enough to mislead someone into cancelling the wrong seat.
Attribution therefore starts empty and fills in as new sessions are recorded;
older rows keep reporting under the provider's `default` lane. The same
conservatism applies to a session already in flight at first observation: its
interval starts before any window, so it stays unattributed until the next
session begins.

### Privacy

`providerAccountID` is stored as the anonymized `acct_sha256_…` partition token
(`TokenUsage.providerAccountIdentityPartition`), matching how account identity
was already hashed before reaching SQLite and Firestore. The raw email or
account id is used only to derive that token. `providerAccountLabel` holds the
human-readable seat name for display.

### Transition from unattributed rows

The `token_usage` unique index includes `COALESCE(providerAccountID, '')`, so a
newly attributed row does not collide with the same session's older
unattributed row. `deleteUnattributedPredecessorRows` retires that predecessor
in the same transaction as the insert, so enabling attribution re-keys history
instead of double-counting it. Rows already attributed to a different account
are never claimed.

### Surfaces

Per-account burn appears in the dashboard **Credential Ranking** lane, in the
per-provider **Spend by Account** panel (shown when more than one account has
usage in the window), and in the org rollup's **credential** group-by.

## Routing Policy

Provider accounts are the router inventory. Quota snapshots are health signals,
not the source of account identity. The shared `ProviderRoutingCandidate` contract
combines provider/account metadata, redacted credential handle, storage scope,
model compatibility, quota state, cooldown, priority, routing enablement,
last-used time, last failure code, and local credential availability.

The router policy prefers healthy, enabled accounts with local credential
availability. It skips deleted, disabled, auth-failed, exhausted, rate-limited,
and still-cooling-down accounts. Unknown quota remains eligible unless a runtime
failure has turned into a hard account-health state. For OpenAI specifically,
usage totals alone do not prove hard exhaustion; runtime 429, insufficient quota,
or auth failures must update account health before the account is blocked.

When multiple eligible accounts can serve the same provider/model route, routing
drains the quota window that expires first. Future weekly reset metadata beats
unknown reset metadata, earlier future resets beat later future resets, and past
reset dates are ignored as stale. This ordering only applies within the same
provider/model/canonical-route pool; it does not resurrect exhausted, auth-failed,
rate-limited, or cooling-down accounts, and it does not silently swap models.

Every route decision produces a UI-readable event with the active account, next
fallback, skipped accounts, and a plain-language reason. Events intentionally omit
raw API keys, bearer tokens, cookies, Secret Manager version names, and credential
handles. The app keeps a capped in-memory trail today; durable persistence can be
added without changing the shared event shape.

Codex in-app chat uses the same switcher profile identity as terminal launches.
When a Codex stream fails with quota text before any assistant/tool output, the
chat bridge marks that profile exhausted for the inferred reset window and
retries the next enabled Codex profile in the same provider, subscription tier,
and model capability class. Once any stream output has been emitted, OpenBurnBar
does not replay the prompt on another account; it surfaces the original error so
side effects are never duplicated.

Legacy single-account installs still route through a synthesized `default`
candidate when no first-class provider account exists. Provider totals remain
separate from account routing health so a provider-level quota rollup cannot hide
which specific account is exhausted or cooling down.

## Compatibility

Legacy `provider_connections/{provider}` documents remain readable during the
transition. The default provider account can mirror the legacy connection so old
clients still see a safe subset. Local usage rows also keep provider-level data
when account attribution is unavailable — providers with no identity resolver,
sessions that span an account switch, and history recorded before attribution
shipped all keep reporting under the provider's `default` lane.

## Deletion

Deleting a cloud account destroys that account's Secret Manager payload, removes
the private mapping, marks the public account metadata as deleted, and marks its
quota snapshots stale. Historical usage keeps the account ID and label for audit
continuity unless a separate data-deletion workflow removes history.
