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

### Connect via SuperGrok login (consumer pacing estimate)

SuperGrok Lite / SuperGrok / SuperGrok Heavy have no public consumer-quota
endpoint, so OpenBurnBar estimates a rolling 2-hour prompt window from local
routing activity. Pick the matching tier in the plan picker; the rolling cap is
community-estimated (Lite 30 / SuperGrok 100 / Heavy 400 prompts per 2h) and the
snapshot is flagged as estimated. Add an `xai-…` inference key in Accounts so the
Mac proxy can route Grok traffic, which also populates the pacing log
(`~/Library/Application Support/OpenBurnBar/xai/superGrok-events.jsonl`).

See [grok.com/plans](https://grok.com/plans) for current tier pricing.

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

Every route decision produces a UI-readable event with the active account, next
fallback, skipped accounts, and a plain-language reason. Events intentionally omit
raw API keys, bearer tokens, cookies, Secret Manager version names, and credential
handles. The app keeps a capped in-memory trail today; durable persistence can be
added without changing the shared event shape.

Legacy single-account installs still route through a synthesized `default`
candidate when no first-class provider account exists. Provider totals remain
separate from account routing health so a provider-level quota rollup cannot hide
which specific account is exhausted or cooling down.

## Compatibility

Legacy `provider_connections/{provider}` documents remain readable during the
transition. The default provider account can mirror the legacy connection so old
clients still see a safe subset. Local usage rows also keep provider-level data
when account attribution is unavailable.

## Deletion

Deleting a cloud account destroys that account's Secret Manager payload, removes
the private mapping, marks the public account metadata as deleted, and marks its
quota snapshots stale. Historical usage keeps the account ID and label for audit
continuity unless a separate data-deletion workflow removes history.
