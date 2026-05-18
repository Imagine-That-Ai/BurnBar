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
  xAI/Grok, and Cohere use the same daemon-slot projection even when they have no
  `AgentProvider` enum case.

Quota snapshots use schema version 2 and include `providerID`, `accountID`,
`accountLabel`, `accountStorageScope`, and `sourceID`. Provider-level views keep
aggregates, while detail views preserve per-account snapshots and unattributed
legacy usage.

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
