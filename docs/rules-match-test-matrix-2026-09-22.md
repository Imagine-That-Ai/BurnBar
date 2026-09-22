# Firestore rules match × test matrix v1

Date: 2026-09-22. Source of truth: [firestore.rules](../firestore.rules) at base
commit `3354f14a1c`, tests in [firestore-rules-tests/](../firestore-rules-tests/).

Method: `grep -c 'match /' firestore.rules` == **104**; every row below names one
match by line number. A row is COVERED only when a test file was inspected and
touches the matched path. Rows covered solely by the parity suite's generic
owner-read/owner-write probes are marked COVERED-BASIC (no schema/validator
depth). UNCOVERED rows are real gaps, not oversights — invented coverage is
failure.

Suite inventory (observed, not assumed): **24** `*.test.js` files plus
`package.json`, `package-lock.json`, and `tools/` (which holds only
`CUClickSmoke/Package.swift`, unrelated to rules). The "28 files" figure in the
task brief does not match this tree; 24 test files were mapped.

Notes that apply to many rows:

- `rules-consolidation-parity.test.js` (below: **parity**) probes the
  consolidated owner gate (`L1997`) across its `OWNER_READABLE_COLLECTIONS`
  allowlist plus a `not_allowlisted` deny probe. It proves reachability, not
  validator depth.
- Firestore ORs overlapping `allow` statements, so the Signal-at-rest mirror
  matches (`L2078`–`L2157`) and the schema matches (`L2215`+) for the same
  collection share covering tests without double-counting.
- `account_erasure_tombstones` has **no** `match` (default deny; enforced via
  `exists()` in `isSignedIn()`, rules `L37`) and therefore has no matrix row.
  The barrier behavior itself is covered by `account-erasure-barrier.test.js`
  and the parity erasure sweep.
- `storage-rules.test.js` targets `storage.rules`; where it also reads
  Firestore `session_logs` docs it is listed as a cross-check only.


> **Adoption provenance (parent, 2026-09-22):** authored by Stream G against base
> `3354f14a1c` (line numbers refer to that revision; Stream E's denylist
> expansion shifted subsequent lines — match *paths* are authoritative, not line
> numbers). Adopted into `docs/` because `launch-evidence/` is gitignored and
> this artifact contains no secrets. Supersedes the parent's grep-heuristic v0
> (89 named / 15 unnamed); this inspected version (52 COVERED / 27
> COVERED-BASIC / 24 UNCOVERED) is the honest one.
>
> 2026-09-22 fixup: 6 operator rows (67-69, 102-104) REMOVED — match blocks
> deleted outright per the dead-`if false` convention; deny-by-default now
> covers them (98 live matches).

## Coverage map

| # | Match (rules line) | Status | Covering test file(s) |
|---|--------------------|--------|-----------------------|
| 1 | `L34` `/databases/{database}/documents` (root scope) | STRUCTURAL | implicit via all suites — scope block, no `allow` of its own |
| 2 | `L1961` `/model_benchmark_snapshots/{snapshotId}` | UNCOVERED | — |
| 3 | `L1965` `/model_benchmark_source_status/{sourceId}` | UNCOVERED | — |
| 4 | `L1987` `/users/{userId}` | COVERED | [rr12-relay-and-root](../firestore-rules-tests/rr12-relay-and-root.test.js) (root-profile writes) · [account-erasure-barrier](../firestore-rules-tests/account-erasure-barrier.test.js) (owner reads) |
| 5 | `L1997` `/users/{userId}/{collectionId}/{documentId}` (consolidated owner gate) | COVERED | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) (full allowlist + `not_allowlisted` deny probe) |
| 6 | `L2078` `/users/{userId}/conversations/{documentId}` (signal mirror) | COVERED | [m007-path-bound-sealed-payload](../firestore-rules-tests/m007-path-bound-sealed-payload.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 7 | `L2086` `/users/{userId}/chat_threads/{documentId}` (signal mirror) | COVERED | [chat-thread-path-bound](../firestore-rules-tests/chat-thread-path-bound.test.js) · [m007-path-bound-sealed-payload](../firestore-rules-tests/m007-path-bound-sealed-payload.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 8 | `L2093` `/users/{userId}/mobile_assistant_chats/{documentId}` (signal mirror) | COVERED | [m007-path-bound-sealed-payload](../firestore-rules-tests/m007-path-bound-sealed-payload.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 9 | `L2101` `/users/{userId}/cli_sessions/{documentId}` (signal mirror) | COVERED | [cli-session-path-bound](../firestore-rules-tests/cli-session-path-bound.test.js) · [m007-path-bound-sealed-payload](../firestore-rules-tests/m007-path-bound-sealed-payload.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 10 | `L2110` `/users/{userId}/text_snippets/{documentId}` | COVERED | [cloud-vault-aad](../firestore-rules-tests/cloud-vault-aad.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 11 | `L2119` `/users/{userId}/rollback_requests/{documentId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 12 | `L2126` `/users/{userId}/approval_policies/{documentId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 13 | `L2134` `/users/{userId}/agent_identities/{documentId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 14 | `L2142` `/users/{userId}/subscription_topics/{documentId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 15 | `L2157` `/users/{userId}/usage/{usageId}` | COVERED | [cloud-vault-aad](../firestore-rules-tests/cloud-vault-aad.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 16 | `L2172` `/users/{userId}/budgetRules/{ruleId}` | COVERED | [cloud-vault-aad](../firestore-rules-tests/cloud-vault-aad.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 17 | `L2187` `/users/{userId}/budgetEvents/{eventId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 18 | `L2215` `/users/{userId}/conversations/{conversationId}` (schema) | COVERED | [m007-path-bound-sealed-payload](../firestore-rules-tests/m007-path-bound-sealed-payload.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 19 | `L2276` `/users/{userId}/chat_threads/{threadId}` (schema) | COVERED | [chat-thread-path-bound](../firestore-rules-tests/chat-thread-path-bound.test.js) · [m007-path-bound-sealed-payload](../firestore-rules-tests/m007-path-bound-sealed-payload.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 20 | `L2280` `/users/{userId}/text_snippets/{snippetId}` (schema) | COVERED | [cloud-vault-aad](../firestore-rules-tests/cloud-vault-aad.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 21 | `L2287` `/users/{userId}/mobile_assistant_chats/{threadId}` (schema) | COVERED | [m007-path-bound-sealed-payload](../firestore-rules-tests/m007-path-bound-sealed-payload.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 22 | `L2328` `/users/{userId}/cli_sessions/{sessionId}` (schema) | COVERED | [cli-session-path-bound](../firestore-rules-tests/cli-session-path-bound.test.js) · [m007-path-bound-sealed-payload](../firestore-rules-tests/m007-path-bound-sealed-payload.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 23 | `L2379` `/users/{userId}/ai_inbox_items/{itemId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 24 | `L2445` `/users/{userId}/ai_inbox_item_state/{itemId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 25 | `L2473` `/users/{userId}/cli_agent_mission_requests/{requestId}` | COVERED | [wand-fanout-cap](../firestore-rules-tests/wand-fanout-cap.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 26 | `L2861` `/events/{eventId}` (nested under mission requests) | COVERED | [wand-fanout-cap](../firestore-rules-tests/wand-fanout-cap.test.js) |
| 27 | `L2899` `/users/{userId}/burnbar_attachments/{attachmentId}` | UNCOVERED | — |
| 28 | `L2903` `/users/{userId}/mission_approval_answers/{answerId}` | UNCOVERED | — |
| 29 | `L2907` `/users/{userId}/mission_approval_ceilings/{requestId}` | UNCOVERED | — |
| 30 | `L2914` `/users/{userId}/agent_import_jobs/{jobId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 31 | `L2973` `/users/{userId}/mission_groups/{groupId}` | COVERED | [wand-fanout-cap](../firestore-rules-tests/wand-fanout-cap.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 32 | `L3071` `/users/{userId}/approval_policies/{policyId}` (schema) | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 33 | `L3103` `/users/{userId}/rollback_requests/{requestId}` (schema) | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 34 | `L3126` `/users/{userId}/cli_sessions/{sessionId}/snapshots/{snapshotId}` | UNCOVERED | — (`snapshots` hits elsewhere are `quota_snapshots`, a different path) |
| 35 | `L3152` `/users/{userId}/agent_identities/{identityId}` (schema) | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 36 | `L3179` `/users/{userId}/subscription_topics/{topicId}` (schema) | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 37 | `L3197` `/users/{userId}/session_logs/{logId}` | COVERED | [session-log-backup](../firestore-rules-tests/session-log-backup.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) · [storage-rules](../firestore-rules-tests/storage-rules.test.js) (cross-check) |
| 38 | `L3201` `/chunks/{chunkId}` (nested under session_logs) | COVERED | [session-log-backup](../firestore-rules-tests/session-log-backup.test.js) (`manifest.path/chunks/…`) |
| 39 | `L3215` `/users/{userId}/project_memory_snapshots/{docID}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 40 | `L3263` `/users/{userId}/memory_facts/{memoryDocId}` | COVERED | [memory-facts-sealed](../firestore-rules-tests/memory-facts-sealed.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 41 | `L3320` `/users/{userId}/memory_forget_receipts/{receiptId}` | COVERED | [memory-facts-sealed](../firestore-rules-tests/memory-facts-sealed.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 42 | `L3376` `/users/{userId}/knowledge_sync_manifests/{sourceManifestId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 43 | `L3378` `/entries/{entryKey}` (nested under knowledge manifests) | UNCOVERED | — (`entries` hits elsewhere are JS `.entries()` calls, not paths) |
| 44 | `L3424` `/users/{userId}/cloud_vault_state/{stateId}` | COVERED | [cloud-vault-generation-monotonic](../firestore-rules-tests/cloud-vault-generation-monotonic.test.js) · [cloud-vault-key-wrappers](../firestore-rules-tests/cloud-vault-key-wrappers.test.js) · [chat-thread-path-bound](../firestore-rules-tests/chat-thread-path-bound.test.js) · [cli-session-path-bound](../firestore-rules-tests/cli-session-path-bound.test.js) · [m007-path-bound-sealed-payload](../firestore-rules-tests/m007-path-bound-sealed-payload.test.js) · [roaming-profile](../firestore-rules-tests/roaming-profile.test.js) · [shared-artifact-sealed](../firestore-rules-tests/shared-artifact-sealed.test.js) · [wand-fanout-cap](../firestore-rules-tests/wand-fanout-cap.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 45 | `L3479` `/users/{userId}/cloud_vault_key_wrappers/{wrapperId}` | COVERED | [cloud-vault-key-wrappers](../firestore-rules-tests/cloud-vault-key-wrappers.test.js) · [rr12-relay-and-root](../firestore-rules-tests/rr12-relay-and-root.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 46 | `L3539` `/users/{userId}/cloud_vault_rotation_jobs/{jobId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 47 | `L3638` `/checkpoints/{checkpointId}` (nested under rotation jobs) | UNCOVERED | — |
| 48 | `L3647` `/users/{userId}/agent_notification_replies/{replyId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 49 | `L3709` `/users/{userId}/provider_accounts/{accountId}` | COVERED | [provider-account-quota-sync](../firestore-rules-tests/provider-account-quota-sync.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 50 | `L3791` `/users/{userId}/roaming_profile/{profileId}` | COVERED | [roaming-profile](../firestore-rules-tests/roaming-profile.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 51 | `L3802` `/users/{userId}/runtime_connection_preferences/{preferenceId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 52 | `L3806` `/users/{userId}/hermes_connections/{connectionId}` | COVERED | [rr12-relay-and-root](../firestore-rules-tests/rr12-relay-and-root.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 53 | `L3840` `/users/{userId}/hermes_bodies/{bodyId}` | UNCOVERED | — |
| 54 | `L3872` `/users/{userId}/war_wire_grants/{pairId}` | UNCOVERED | — |
| 55 | `L3884` `/users/{userId}/hermes_relay_requests/{requestId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only — `relayRequestWrite` validator has no depth test (rr12 covers the Pi relay analogue, not Hermes) |
| 56 | `L3887` `/chunks/{chunkId}` (nested under hermes_relay_requests) | UNCOVERED | — |
| 57 | `L3948` `/users/{userId}/iroh_pairing/{connectionId}` | COVERED | [computer-use](../firestore-rules-tests/computer-use.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 58 | `L3960` `/users/{userId}/iroh_audit_events/{eventId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 59 | `L4006` `/users/{userId}/media_session_events/{eventId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 60 | `L4055` `/users/{userId}/iroh_pairing/{connectionId}/controllers/{peerNodeId}` | COVERED | [computer-use](../firestore-rules-tests/computer-use.test.js) |
| 61 | `L4069` `/users/{userId}/iroh_pairing/{connectionId}/controller_routes/{sourceDeviceId}` | UNCOVERED | — |
| 62 | `L4076` `/users/{userId}/iroh_controller_route_challenges/{challengeId}` | UNCOVERED | — |
| 63 | `L4092` `/users/{userId}/agent_capability_grant_requests/{requestId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 64 | `L4158` `/users/{userId}/computer_use_sessions/{sessionId}` | COVERED | [computer-use](../firestore-rules-tests/computer-use.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 65 | `L4169` `/users/{userId}/computer_use_actions/{actionId}` | COVERED | [computer-use](../firestore-rules-tests/computer-use.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 66 | `L4179` `/ops/computer_use_budget_status/state/current` | COVERED | [computer-use](../firestore-rules-tests/computer-use.test.js) |
| 67 | ~~`/ops/computer_use_budget_status/metrics/current`~~ | REMOVED 2026-09-22 | match block deleted; default deny (operator retirement; deny asserted by computer-use suite) |
| 68 | ~~`/ops/computer_use_budget_status/events/{eventId}`~~ | REMOVED 2026-09-22 | match block deleted; default deny (deny asserted by computer-use suite) |
| 69 | ~~`/ops/computer_use_session_daily_rollups/days/{day}`~~ | REMOVED 2026-09-22 | match block deleted; default deny (deny asserted by computer-use suite) |
| 70 | `L4208` `/users/{userId}/media_attachment_manifests/{manifestId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 71 | `L4242` `/users/{userId}/pi_agent_connections/{connectionId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 72 | `L4250` `/users/{userId}/pi_agent_relay_requests/{requestId}` | COVERED | [rr12-relay-and-root](../firestore-rules-tests/rr12-relay-and-root.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 73 | `L4253` `/chunks/{chunkId}` (nested under pi_agent_relay_requests) | UNCOVERED | — |
| 74 | `L4261` `/users/{userId}/smart_hub_config/{deviceId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 75 | `L4288` `/users/{userId}/smart_display_actions/{actionId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 76 | `L4334` `/users/{userId}/cast_actions/{actionId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 77 | `L4370` `/users/{userId}/cast_discovery_results/{resultId}` | COVERED-BASIC | [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) only |
| 78 | `L4386` `/users/{userId}/linux_app_check_devices/{deviceId}` | COVERED | [linux-app-check-server-only](../firestore-rules-tests/linux-app-check-server-only.test.js) |
| 79 | `L4393` `/users/{userId}/linux_app_check_challenges/{challengeId}` | COVERED | [linux-app-check-server-only](../firestore-rules-tests/linux-app-check-server-only.test.js) |
| 80 | `L4403` `/users/{userId}/billing/allowances/months/{monthKey}` | COVERED | [billing-allowance-owner-read](../firestore-rules-tests/billing-allowance-owner-read.test.js) |
| 81 | `L4436` `/users/{userId}/escrow_devices/{deviceId}` | COVERED | [signal-prekey-server-only](../firestore-rules-tests/signal-prekey-server-only.test.js) · [computer-use](../firestore-rules-tests/computer-use.test.js) · [cloud-vault-key-wrappers](../firestore-rules-tests/cloud-vault-key-wrappers.test.js) · [escrow-grants](../firestore-rules-tests/escrow-grants.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 82 | `L4606` `/computer_use_audit_export_signers/{signerId}` (nested under escrow_devices) | COVERED | [computer-use](../firestore-rules-tests/computer-use.test.js) |
| 83 | `L4699` `/users/{userId}/escrow_public_keys/{keyId}` | COVERED | [cloud-vault-aad](../firestore-rules-tests/cloud-vault-aad.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 84 | `L4764` `/users/{userId}/signal_identity_public_keys/{keyId}` | COVERED | [signal-prekey-server-only](../firestore-rules-tests/signal-prekey-server-only.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 85 | `L4851` `/signed_prekeys/{signedPreKeyId}` (nested under signal identities) | COVERED | [signal-prekey-server-only](../firestore-rules-tests/signal-prekey-server-only.test.js) |
| 86 | `L4856` `/one_time_prekeys/{oneTimePreKeyId}` (nested under signal identities) | COVERED | [signal-prekey-server-only](../firestore-rules-tests/signal-prekey-server-only.test.js) |
| 87 | `L4861` `/kyber_prekeys/{kyberPreKeyId}` (nested under signal identities) | COVERED | [signal-prekey-server-only](../firestore-rules-tests/signal-prekey-server-only.test.js) |
| 88 | `L4866` `/sessions/{sessionId}` (nested under signal identities) | COVERED | [signal-prekey-server-only](../firestore-rules-tests/signal-prekey-server-only.test.js) |
| 89 | `L4871` `/rotation_events/{rotationId}` (nested under signal identities) | COVERED | [signal-prekey-server-only](../firestore-rules-tests/signal-prekey-server-only.test.js) |
| 90 | `L4877` `/users/{userId}/escrow_grants/{grantId}` | COVERED | [escrow-grants](../firestore-rules-tests/escrow-grants.test.js) |
| 91 | `L4945` `/users/{userId}/escrow_envelopes/{envelopeId}` | COVERED | [escrow-audit-append-only](../firestore-rules-tests/escrow-audit-append-only.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 92 | `L4993` `/users/{userId}/escrow_audit_events/{eventId}` | COVERED | [escrow-audit-append-only](../firestore-rules-tests/escrow-audit-append-only.test.js) · [parity](../firestore-rules-tests/rules-consolidation-parity.test.js) |
| 93 | `L5010` `/workspaces/{workspaceId}/teams/{teamId}/artifacts/{artifactId}` | COVERED | [shared-artifact-sealed](../firestore-rules-tests/shared-artifact-sealed.test.js) |
| 94 | `L5015` `/versions/{revisionId}` (nested under artifacts) | COVERED | [shared-artifact-sealed](../firestore-rules-tests/shared-artifact-sealed.test.js) |
| 95 | `L5031` `/team_rosters/{teamId}` | UNCOVERED | — |
| 96 | `L5034` `/members/{memberUid}` (nested under team_rosters) | UNCOVERED | — |
| 97 | `L5043` `/audit_log/{eventId}` (nested under team_rosters) | UNCOVERED | — (`audit_log` hits elsewhere are `unified_audit_log`, a different path) |
| 98 | `L5063` `/team_key_envelopes/{teamId}/envelopes/{envelopeId}` | UNCOVERED | — |
| 99 | `L5132` `/team_memory_facts/{teamId}/facts/{docID}` | UNCOVERED | — |
| 100 | `L5213` `/team_memory_facts/{teamId}/forget_receipts/{receiptId}` | UNCOVERED | — (only personal `memory_forget_receipts` is tested) |
| 101 | `L5250` `/ops/media_budget_status/state/current` | COVERED | [media-budget](../firestore-rules-tests/media-budget.test.js) |
| 102 | ~~`/ops/media_budget_status/metrics/current`~~ | REMOVED 2026-09-22 | match block deleted; default deny (deny asserted by media-budget suite) |
| 103 | ~~`/ops/media_budget_status/events/{eventId}`~~ | REMOVED 2026-09-22 | match block deleted; default deny (deny asserted by media-budget suite) |
| 104 | ~~`/ops/media_session_daily_rollups/{document=**}`~~ | REMOVED 2026-09-22 | match block deleted; default deny (deny asserted by media-budget suite) |

## Totals

104 match rows: **1** structural, **52** COVERED (depth test + usually parity),
**27** COVERED-BASIC (parity probes only), **24** UNCOVERED.

UNCOVERED clusters, for triage: team surface (`L5031`–`L5213`, 6 rows, includes
the whole team-key-envelope + team-memory-facts trust boundary); ops
events/rollups (`L4185`, `L4188`, `L5256`, `L5260`); Hermes bodies/grants/chunks
(`L3840`, `L3872`, `L3887`) + Pi relay chunks (`L4253`); iroh controller routes
(`L4069`, `L4076`); mission-approval + attachments (`L2899`, `L2903`, `L2907`);
nested entries/checkpoints/snapshots (`L3126`, `L3378`, `L3638`); public
model-landscape reads (`L1961`, `L1965`).

Known CI caveat (not a matrix gap): `security-pr.yml` runs
`test:session-log-backup` as non-blocking (`continue-on-error`) because of 3
pre-existing Pro-entitlement failures documented in the workflow. Rows 37–38
are COVERED by that suite, but its reds are currently unenforced at PR time.
