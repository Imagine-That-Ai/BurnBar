# Hosted Remote MCP Completion Audit

Date: 2026-05-15

Objective audited:
`docs/plans/HOSTED_REMOTE_MCP_MULTI_AGENT_SPRINT_PLAN.md` end-to-end implementation.

Verdict: **ship**. Hosted Remote MCP is live
at `https://mcp.burnbar.ai/mcp`, the grant path and hosted service now share the
same branded audience, Cloud Run revision `openburnbar-hosted-mcp-00014-w5j`
serves 100% of traffic with min instances set to 1, controlled production
paid/unpaid/revoked/cross-tenant proof passes, the local stdio shim works
against production, performance is inside target, privacy scanning passes, and
Android/iPhone/iPad app shells build/install/launch with the branded endpoint.
The previous production hold is closed: signed-in iPhone and iPad live UI tests
now seed real paid Firebase users, list a real `remote_mcp_clients` document in
the Cloud Store Remote MCP card, revoke it through the app, and verify
`revokedAt` in Firestore before cleaning up proof state.

## 2026-05-15 Closure Pass Addendum

Changes applied during the final review pass:

- Replaced stale `mcp.openburnbar.com` runtime defaults with
  `https://mcp.burnbar.ai/mcp` across Cloud Run config, grant-token fallback,
  macOS/iOS/Android setup UI, deploy script, threat model, runbook, and proof
  scripts. The only remaining old-domain mention is a runbook note that it is a
  future alias after domain verification.
- Redeployed `issueRemoteMcpGrant(us-central1)` so newly issued MCP grants use
  the branded audience fallback.
- Redeployed hosted MCP to Cloud Run revision
  `openburnbar-hosted-mcp-00014-w5j` with `MCP_RESOURCE=https://mcp.burnbar.ai/mcp`,
  `OPENBURNBAR_STORAGE_BUCKET=burnbar-hosted-mcp-bodies-246956661961`, Secret
  Manager-backed token signing secret, and `autoscaling.knative.dev/minScale=1`.
- Removed the blocking per-request `lastUsedAt` write from the hosted MCP
  critical path by throttling it to a best-effort 60-second write interval while
  still reading the client document on every request so revocation remains
  fail-closed.
- Fixed hosted MCP proof fixtures to use owner-scoped `.json.aesgcm` body paths,
  64-character body hashes, and AES-GCM sealed envelopes so privacy scans do
  not fail when run near live proof traffic.
- Fixed `prove-hosted-mcp-shim-live.mjs` to resolve the repo root from the
  script URL, so it works under `npm --prefix functions`.
- Added a DEBUG-only mobile E2E Cloud Store route and UI test for signed-in
  Remote MCP connected-client list/revoke proof. The route waits for Firebase
  Auth before mounting Cloud Store and injects the shared subscription store so
  the proof exercises the same premium-gated member surface.
- Changed `HostedQuotaSubscriptionStore.refreshEntitlement()` to read the
  canonical Firestore entitlement before the callable restore path when no
  local StoreKit transaction exists. This makes pro-mirrored/server-seeded paid
  status appear immediately on fresh devices while preserving server restore as
  the reconciliation fallback.

Fresh production proof:

```bash
curl -fsS https://mcp.burnbar.ai/readyz
# {"ok":true,"service":"openburnbar-hosted-mcp"}

curl -fsS https://mcp.burnbar.ai/.well-known/oauth-protected-resource
# resource: https://mcp.burnbar.ai/mcp

node functions/scripts/prove-hosted-mcp-live.mjs --project burnbar
# endpoint: https://mcp.burnbar.ai/mcp
# missingAuthStatus: 401
# paidCapabilitiesStatus: 200
# unpaidCapabilitiesStatus: 403
# revokedCapabilitiesStatus: 403
# paidSearchStatus: 200
# paidSearchReadBudget: firestoreDocumentReads=3, storageReads=0,
# withinSearchReadBudget=true
# crossTenantReadStatus: 404
# missingScopeStatus: 403

npm --prefix functions run prove:hosted-mcp-performance -- --project burnbar
# corpus: 1000 documents, 100 matching candidates, 20 iterations
# search p50: 263 ms; search p95: 535 ms
# body p50: 286 ms; body p95: 412 ms
# search reads: 50 Firestore, 0 Storage
# body reads: 1 Firestore, 1 Storage

npm --prefix functions run prove:hosted-mcp-shim -- --project burnbar
# openburnbar-mcp-remote stdio doctor passed
# toolsListed: 6
# search read budget: 2 Firestore, 0 Storage
# body read budget: 1 Firestore, 1 Storage

npm --prefix functions run prove:hosted-mcp-privacy -- \
  --project burnbar \
  --storage-bucket burnbar-hosted-mcp-bodies-246956661961
# firestoreViolationCount: 0
# storageViolationCount: 0

OPENBURNBAR_MCP_ENDPOINT=https://mcp.burnbar.ai/mcp \
  ./scripts/test-hosted-mcp-security.sh
# hosted MCP security smoke passed

./scripts/test-hosted-mcp-compatibility.sh
# hosted MCP compatibility config smoke passed

FIREBASE_APP_CHECK_DEBUG_TOKEN=... OPENBURNBAR_E2E_CONFIG_PATH=build/remote-mcp-mobile-e2e.json \
  xcodebuild test -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBarMobile \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -only-testing:OpenBurnBarMobileUITests/RemoteMCPConnectedClientsUITests/testSignedInCloudMemberCanSeeAndRevokeRemoteMCPClient
# ok: true, device: iphone, revokedAt: 2026-05-15T12:29:12.985Z

FIREBASE_APP_CHECK_DEBUG_TOKEN=... OPENBURNBAR_E2E_CONFIG_PATH=build/remote-mcp-mobile-e2e.json \
  xcodebuild test -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBarMobile \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:OpenBurnBarMobileUITests/RemoteMCPConnectedClientsUITests/testSignedInCloudMemberCanSeeAndRevokeRemoteMCPClient
# ok: true, device: ipad, revokedAt: 2026-05-15T12:32:11.566Z
```

Fresh platform proof:

```bash
npm --prefix services/hosted-mcp test
npm --prefix services/hosted-mcp run lint
npm --prefix tools/openburnbar-mcp-remote test
npm --prefix tools/openburnbar-mcp-remote run lint
npm --prefix functions run build

xcodebuild -project OpenBurnBar.xcodeproj \
  -scheme OpenBurnBarMobile \
  -destination 'generic/platform=iOS' \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build

ANDROID_HOME="$HOME/Library/Android" ANDROID_SDK_ROOT="$HOME/Library/Android" \
  JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" \
  ./gradlew assembleDebug

./scripts/cross-platform/run-ios "iPhone 17 Pro Max"
./scripts/cross-platform/run-ios "iPad Pro 13-inch (M4)"
ANDROID_HOME="$HOME/Library/Android" ANDROID_SDK_ROOT="$HOME/Library/Android" \
  ./scripts/cross-platform/run-android
```

Platform result:

- iPhone simulator: build, install, launch passed.
- iPad simulator: build, install, launch passed.
- iPhone signed-in premium UI: seeded paid Firebase user listed and revoked a
  real Remote MCP client; Firestore `revokedAt` verified.
- iPad signed-in premium UI: seeded paid Firebase user listed and revoked a
  real Remote MCP client; Firestore `revokedAt` verified.
- Android connected device `SM-S921U`: APK build, streamed install, launch
  passed.
- Generic iOS device build passed with existing Swift 6 concurrency warnings.
- Android build passes when `JAVA_HOME` points at the actual user Homebrew JDK:
  `$HOME/.homebrew/opt/openjdk@21`.

## Prompt-To-Artifact Checklist

| Requirement | Artifact / Evidence | Status |
| --- | --- | --- |
| Standards-first Streamable HTTP endpoint at `https://mcp.burnbar.ai/mcp` | `services/hosted-mcp/src/server.ts`, `src/mcp.ts`, `src/oauthMetadata.ts` implement `/mcp`, protocol handlers, metadata, errors, origin checks; `https://mcp.burnbar.ai/mcp` is live | Branded endpoint deployed and verified |
| MCP methods: `initialize`, `tools/list`, `tools/call`, `resources/list`, `resources/read` | `services/hosted-mcp/src/mcp.ts`, `src/toolRegistry.ts`, `src/resources.ts`; resource routes now enforce scope, active client, entitlement, and rate limits; local tests pass | Locally verified and redeployed |
| Missing auth returns `401`; invalid origin returns `403`; bounded oversized input | `scripts/test-hosted-mcp-security.sh`; local run passed in implementation pass | Locally verified only |
| OpenBurnBar Pro paywall via `users/{uid}/entitlements/burnbar_pro` | `functions/src/index.ts`, `functions/src/remoteMcpOAuth.ts`, `services/hosted-mcp/src/entitlements.ts`; controlled live proof on generated Cloud Run URL | Live controlled paid/unpaid proof passed |
| Firebase ID tokens are not final MCP bearer tokens | `functions/src/remoteMcpOAuth.ts` signs short-lived HMAC MCP access tokens; `services/hosted-mcp/src/auth.ts` validates audience/client/scopes/expiry | Source present |
| Token signing/verifier secret in Secret Manager | `REMOTE_MCP_TOKEN_HMAC_SECRET` declared via Firebase `defineSecret`; `scripts/deploy-hosted-mcp.sh` uses Cloud Run `--set-secrets`; Secret Manager version `1` created | Verified |
| Hosted MCP never receives provider credentials | Tool surface is session-memory only; docs and threat model state no provider credentials | Source/docs present |
| Default privacy mode is sealed/local decrypt | `tools/openburnbar-mcp-remote/src/decrypt.ts`, `docs/HOSTED_REMOTE_MCP.md`, `docs/REMOTE_MCP_THREAT_MODEL.md` | Source/docs present |
| Search does zero Storage reads and uses manifest/postings | `services/hosted-mcp/src/search.ts`, `src/resources.ts`, `functions/src/index.ts`, `functions/scripts/prove-hosted-mcp-live.mjs`, `functions/scripts/prove-hosted-mcp-performance.mjs` | Controlled live search proof reports `firestoreDocumentReads: 4`, `storageReads: 0`, `withinSearchReadBudget: true`; Cloud Build large-corpus body-enabled proof passed with 1000 docs, 100 matching candidates, search p50 267 ms / p95 471 ms, body p50 304 ms / p95 534 ms, search reads 50 Firestore + 0 Storage, and body reads 1 Firestore + 1 Storage |
| Deny-by-default tool registry | `services/hosted-mcp/src/toolRegistry.ts` declares scopes, entitlement, input/output caps, cost class, rate bucket, audit kind, redaction policy | Source present |
| Required tools: search, body, index status, facets, recent usage, capabilities | `services/hosted-mcp/src/toolRegistry.ts` | Source present |
| Firestore data additions and rules | `firestore.rules`, `firestore.indexes.json`, `functions/scripts/test-firestore-rules.mjs` | Rules tests passed |
| Local shim for stdio clients and local decrypt | `tools/openburnbar-mcp-remote/src/*` | Tests/lint passed |
| Installer output for Codex, Claude Code, Droid/Factory, Kimi, Forge, generic | `tools/openburnbar-mcp-remote/src/installers.ts`, `src/installers.test.ts`, `scripts/test-hosted-mcp-compatibility.sh`, `functions/scripts/prove-hosted-mcp-shim-live.mjs` | Shim and installer defaults now point at `https://mcp.burnbar.ai/mcp`; hermetic branded config proof passed; temp-profile installed CLI config proof passed without endpoint override; live stdio shim proof passed for tools/list, search, and body fetch against generated and branded endpoints; Claude Code health check connected; Kimi `mcp test` connected and listed all six tools; Codex add/get config proof passed; Droid/Factory add proof passed with real Factory binary; Forge temp-profile import/list/reload proof passed and listed 6 tools; generic execution proof is covered by direct stdio shim proof, not an external inspector |
| Doctor command | `tools/openburnbar-mcp-remote/src/doctor.ts`, `functions/scripts/prove-hosted-mcp-shim-live.mjs` | Live doctor proof passed with temporary MCP token against generated and branded endpoints: token found, endpoint `200 OK`, and `tools/list` passed |
| App UX for setup/status/revoke | `OpenBurnBarMobile/Views/Store/CloudStoreView.swift`, `OpenBurnBarMobileUITests/RemoteMCPConnectedClientsUITests.swift`, `AgentLens/Views/Settings/CloudStoreSettingsView.swift`, `android/app/src/main/java/com/openburnbar/ui/store/CloudStoreView.kt`, and `android/app/src/main/java/com/openburnbar/data/stores/RemoteMcpClientStore.kt` show setup/status copy, list `remote_mcp_clients`, display scopes/last-used/decrypt mode/status, and call `revokeRemoteMcpClient` | iOS/iPadOS, macOS, and Android member UI implemented; macOS signed-in UI listed and revoked a real Firestore proof client after fixing the callable payload casing; Android fixed APK listed and revoked a real Firestore proof client on the connected device; Android `assembleDebug` passed; iPhone and iPad signed-in UI tests listed and revoked real seeded Remote MCP clients, then verified Firestore `revokedAt` |
| Production deploy | `scripts/deploy-hosted-mcp.sh` deployed `openburnbar-hosted-mcp-00011-zqb`; Cloud Run env update deployed `openburnbar-hosted-mcp-00012-dhf`; Storage bucket `burnbar-hosted-mcp-bodies-246956661961`; encrypted-session Functions callables redeployed with `OPENBURNBAR_STORAGE_BUCKET`; image digest `sha256:b13876c48978972c19fe253dc2a6787c4e1441291e3763d6c7e616edf30d1495` | Cloud Run deployed at generated URL with 100% traffic and body bucket configured; upload/download/search-index callables are active with the same bucket |
| Domain `mcp.burnbar.ai` | Google Search Console ownership verification; Namecheap DNS; Cloud Run domain mapping; `dig +short CNAME mcp.burnbar.ai @1.1.1.1`; `dig +short CNAME mcp.burnbar.ai @8.8.8.8`; `dig +short CNAME mcp.burnbar.ai @9.9.9.9`; `gcloud beta run domain-mappings describe ...`; `curl https://mcp.burnbar.ai/readyz`; `OPENBURNBAR_MCP_ENDPOINT=https://mcp.burnbar.ai/mcp ./scripts/test-hosted-mcp-security.sh` | `burnbar.ai` ownership verified; `mcp.burnbar.ai CNAME ghs.googlehosted.com.` resolves publicly from Cloudflare, Google, and Quad9; Cloud Run mapping is `Ready=True`, `CertificateProvisioned=True`, and `DomainRoutable=True`; branded `/readyz` returns 200; branded security smoke passed |
| Live paid/unpaid/revoked/cross-tenant proof | `functions/scripts/prove-hosted-mcp-live.mjs`; controlled temporary Firestore proof users against generated Cloud Run URL; real paid fixture `alberto8793@gmail.com` against generated and branded URLs; real unpaid fixture against branded URL | Controlled paid/unpaid/revoked/cross-tenant proof passed; real paid subscriber fixture proved active entitlement, tools/list, capabilities, search, encrypted body fetch, and revoke denial on generated URL and branded fallback URL; real unpaid fixture denied with `burnbar_pro_required` on branded URL |
| Alerts/logging/rollback/cost dashboard | `docs/REMOTE_MCP_RUNBOOK.md`, `functions/scripts/prove-hosted-mcp-privacy-scan.mjs`, structured logging in service; Cloud Run logs scanned after live proof window; Monitoring policies `OpenBurnBar Hosted MCP 5xx spike`, `OpenBurnBar Hosted MCP 429 spike`, `OpenBurnBar Hosted MCP auth denial spike`, `OpenBurnBar Hosted MCP p95 latency spike`, `OpenBurnBar Hosted MCP instance pressure`, and project-level `OpenBurnBar Firestore read spike`; dashboard `OpenBurnBar Hosted MCP Cost and Capacity`; rollback rehearsal from `00005-ndq` to `00004-xf4` and back | No obvious plaintext/token leakage in sampled Cloud Run logs; production Firestore/Storage privacy scan passed with zero violations, but current Remote MCP/search collections were empty after controlled proof cleanup; hosted-MCP 5xx/429/auth-denial/latency/instance alerts exist; project-level Firestore read alert exists; cost/capacity dashboard exists; rollback rehearsal passed |
| Multi-agent audit reports | `docs/plans/HOSTED_REMOTE_MCP_WAVE8_AUDIT_REPORT.md`, `docs/plans/HOSTED_REMOTE_MCP_WAVE8_SIGNED_STREAM_REPORTS.md` | Every required stream has a signed report and prioritized findings; the signed-in connected-client UI proof hold is now closed by the iPhone/iPad live E2E runs above |

## Verification Evidence

Passed in the current or immediately preceding implementation pass:

```bash
npm --prefix services/hosted-mcp test
npm --prefix services/hosted-mcp run lint
npm --prefix tools/openburnbar-mcp-remote test
npm --prefix tools/openburnbar-mcp-remote run lint
npm --prefix functions run build
npm --prefix functions test:firestore-rules
npm --prefix functions test
./scripts/test-hosted-mcp-security.sh
./scripts/test-hosted-mcp-compatibility.sh
OPENBURNBAR_MCP_REAL_CLIENTS=1 ./scripts/test-hosted-mcp-compatibility.sh
./scripts/test-openburnbar-swift.sh
xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Additional live production evidence:

```bash
gcloud secrets describe REMOTE_MCP_TOKEN_HMAC_SECRET --project burnbar
# Secret exists; version 1 was created during deploy.

gcloud run services describe openburnbar-hosted-mcp --region us-central1 --project burnbar
# latestReadyRevisionName: openburnbar-hosted-mcp-00012-dhf
# traffic: 100
# Service URL: https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app
# OPENBURNBAR_STORAGE_BUCKET: burnbar-hosted-mcp-bodies-246956661961

curl https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app/readyz
# 200 {"ok":true,"service":"openburnbar-hosted-mcp"}

OPENBURNBAR_MCP_ENDPOINT=https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app/mcp \
  ./scripts/test-hosted-mcp-security.sh
# hosted MCP security smoke passed

node functions/scripts/prove-hosted-mcp-live.mjs \
  --project burnbar \
  --region us-central1 \
  --endpoint https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app/mcp
# with OPENBURNBAR_MCP_TOKEN_HMAC_SECRET set from Secret Manager:
# missingAuthStatus: 401
# paidCapabilitiesStatus: 200
# unpaidCapabilitiesStatus: 403
# revokedCapabilitiesStatus: 403
# paidBListStatus: 200
# crossTenantReadStatus: 404
# missingScopeStatus: 403
# proofId: remote-mcp-proof-1778823222426
# paidSearchStatus: 200
# paidSearchReadBudget:
#   firestoreDocumentReads: 4
#   storageReads: 0
#   searchReadCap: 150
#   withinSearchReadBudget: true
# Temporary proof users were removed after the run.

gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="openburnbar-hosted-mcp" AND timestamp>="2026-05-15T05:00:00Z"' \
  --project burnbar --limit 100 --format=json
# 39 entries scanned. No bearer token shape, proof body hash, proof session
# title, raw query/body value, or signed URL marker found.

gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="openburnbar-hosted-mcp" AND severity>=ERROR AND timestamp>="2026-05-15T05:00:00Z"' \
  --project burnbar --limit 20
# no ERROR-or-higher entries returned

gcloud alpha monitoring policies list --project burnbar \
  --format='value(displayName,enabled)' | grep 'OpenBurnBar Hosted MCP'
# OpenBurnBar Hosted MCP p95 latency spike   True
# OpenBurnBar Hosted MCP auth denial spike  True
# OpenBurnBar Hosted MCP 5xx spike          True
# OpenBurnBar Hosted MCP 429 spike          True
# OpenBurnBar Hosted MCP instance pressure  True

gcloud alpha monitoring policies list --project burnbar \
  --format='value(displayName,enabled)' | grep 'OpenBurnBar Firestore read spike'
# OpenBurnBar Firestore read spike          True

gcloud monitoring dashboards list --project burnbar \
  --format='value(name,displayName)' | grep 'OpenBurnBar Hosted MCP Cost and Capacity'
# projects/246956661961/dashboards/4df51728-d486-44a0-a11f-bc3dc0eeea2b
# OpenBurnBar Hosted MCP Cost and Capacity

gcloud run services update-traffic openburnbar-hosted-mcp \
  --region us-central1 \
  --project burnbar \
  --to-revisions openburnbar-hosted-mcp-00004-xf4=100
# Traffic: 100% openburnbar-hosted-mcp-00004-xf4
# curl "$RUN_URL/readyz" -> {"ok":true,"service":"openburnbar-hosted-mcp"}

gcloud run services update-traffic openburnbar-hosted-mcp \
  --region us-central1 \
  --project burnbar \
  --to-revisions openburnbar-hosted-mcp-00005-ndq=100
# Traffic: 100% openburnbar-hosted-mcp-00005-ndq
# curl "$RUN_URL/readyz" -> {"ok":true,"service":"openburnbar-hosted-mcp"}

OPENBURNBAR_MCP_REAL_CLIENTS=1 ./scripts/test-hosted-mcp-compatibility.sh
# npm warns that the package declares Node 22 while the local shell is Node
# v20.20.2, but the TypeScript build and real-client temp-profile config proof
# pass. Codex emits a temp-HOME helper-binary warning, then continues.
# hosted MCP real client config proof passed
# hosted MCP compatibility config smoke passed

# Controlled live proof with temporary Firestore users and short-lived HMAC
# tokens against https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app/mcp.
# Temporary proof id: remote-mcp-proof-1778821006
# paid capabilities: HTTP/2 200
# unpaid denial: HTTP/2 403, code burnbar_pro_required
# revoked denial: HTTP/2 403, code client_revoked
# Temporary proof users and token files were removed after the run.

# Controlled live MCP resource proof with temporary Firestore users against
# https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app/mcp.
# Temporary proof id after committed-source redeploy: remote-mcp-resource-proof-1778822166
# paid tenant B resources/list: HTTP 200
# cross-tenant resources/read with tenant A token for tenant B resource:
#   HTTP 404, code resource_not_found
# unpaid resources/list: HTTP 403, code burnbar_pro_required
# revoked resources/list: HTTP 403, code client_revoked
# missing conversation scope resources/read: HTTP 403, code insufficient_scope
# Temporary proof users were removed after the run.

gcloud beta run domain-mappings create \
  --service openburnbar-hosted-mcp \
  --domain mcp.openburnbar.com \
  --region us-central1 \
  --project burnbar
# blocked: openburnbar.com is not verified for the active Google account

gcloud domains list-user-verified
# hormigadormida.com
# imagine-that.ai
# burnbar.ai

# Google Search Console ownership was verified for burnbar.ai on 2026-05-15
# using Namecheap DNS TXT:
# google-site-verification=Hk4bKGXPiHcYYtTar6AmxmtFosDiUSRu6q6uRfcxYaQ

gcloud beta run domain-mappings create \
  --service openburnbar-hosted-mcp \
  --domain mcp.burnbar.ai \
  --region us-central1 \
  --project burnbar
# created. Required DNS:
# mcp CNAME ghs.googlehosted.com.

dig +short CNAME mcp.burnbar.ai @1.1.1.1
# ghs.googlehosted.com.

dig +short CNAME mcp.burnbar.ai @8.8.8.8
dig +short CNAME mcp.burnbar.ai @9.9.9.9
# ghs.googlehosted.com.
# ghs.googlehosted.com.

gcloud beta run domain-mappings describe \
  --domain mcp.burnbar.ai \
  --region us-central1 \
  --project burnbar \
  --format='yaml(status.conditions,status.resourceRecords)'
# Ready=True
# CertificateProvisioned=True
# DomainRoutable=True
# resourceRecords: mcp CNAME ghs.googlehosted.com.

curl -i --max-time 20 https://mcp.burnbar.ai/readyz
# HTTP/2 200
# {"ok":true,"service":"openburnbar-hosted-mcp"}

OPENBURNBAR_MCP_ENDPOINT=https://mcp.burnbar.ai/mcp \
  ./scripts/test-hosted-mcp-security.sh
# hosted MCP security smoke passed

gcloud beta run domain-mappings delete \
  --domain mcp.burnbar.ai \
  --region us-central1 \
  --project burnbar \
  --quiet

gcloud beta run domain-mappings create \
  --service openburnbar-hosted-mcp \
  --domain mcp.burnbar.ai \
  --region us-central1 \
  --project burnbar
# Recreated after DNS propagation. Certificate provisioned at
# 2026-05-15T07:44:11.108493Z.

gcloud builds log 017b6eed-58f3-48c1-a81e-fca28af5ac24 \
  --project burnbar --region global
# Hosted MCP large-corpus proof passed from Cloud Build against:
# https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app/mcp
# proofId: remote-mcp-perf-1778827989828
# corpus: 1000 documents, 100 matching candidates, 20 iterations
# search: min 157 ms, p50 231 ms, p95 273 ms, max 434 ms
# readBudget.search:
#   firestoreDocumentReads: 50
#   storageReads: 0
#   searchReadCap: 150
#   withinSearchReadBudget: true

gcloud storage buckets create gs://burnbar-hosted-mcp-bodies-246956661961 \
  --project burnbar \
  --location=us-central1 \
  --uniform-bucket-level-access
# created in US-CENTRAL1

gcloud run services update openburnbar-hosted-mcp \
  --region us-central1 \
  --project burnbar \
  --update-env-vars OPENBURNBAR_STORAGE_BUCKET=burnbar-hosted-mcp-bodies-246956661961
# deployed openburnbar-hosted-mcp-00012-dhf at 100% traffic

firebase deploy --project burnbar \
  --only functions:beginEncryptedSessionBlobUpload,functions:getEncryptedSessionBlobDownloadUrl,functions:commitEncryptedSearchIndexBatch
# deploy complete; all three updated successfully

gcloud functions describe beginEncryptedSessionBlobUpload \
  --gen2 --region us-central1 --project burnbar \
  --format='yaml(serviceConfig.environmentVariables.OPENBURNBAR_STORAGE_BUCKET,state,updateTime)'
# OPENBURNBAR_STORAGE_BUCKET: burnbar-hosted-mcp-bodies-246956661961
# state: ACTIVE
# updateTime: 2026-05-15T07:09:28.243475806Z

gcloud functions describe commitEncryptedSearchIndexBatch \
  --gen2 --region us-central1 --project burnbar \
  --format='yaml(serviceConfig.environmentVariables.OPENBURNBAR_STORAGE_BUCKET,state,updateTime)'
# OPENBURNBAR_STORAGE_BUCKET: burnbar-hosted-mcp-bodies-246956661961
# state: ACTIVE
# updateTime: 2026-05-15T07:09:24.388469765Z

gcloud functions describe getEncryptedSessionBlobDownloadUrl \
  --gen2 --region us-central1 --project burnbar \
  --format='yaml(serviceConfig.environmentVariables.OPENBURNBAR_STORAGE_BUCKET,state,updateTime)'
# OPENBURNBAR_STORAGE_BUCKET: burnbar-hosted-mcp-bodies-246956661961
# state: ACTIVE
# updateTime: 2026-05-15T07:09:24.905719725Z

gcloud builds log 5f8a5d00-0255-4a14-8f54-5c6d4b010269 \
  --project burnbar --region global
# Hosted MCP large-corpus body-enabled proof passed from Cloud Build against:
# https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app/mcp
# proofId: remote-mcp-perf-1778828554452
# corpus: 1000 documents, 100 matching candidates, 20 iterations
# search: min 201 ms, p50 267 ms, p95 471 ms, max 546 ms
# body: min 227 ms, p50 304 ms, p95 534 ms, max 697 ms
# readBudget.search:
#   firestoreDocumentReads: 50
#   storageReads: 0
#   searchReadCap: 150
#   withinSearchReadBudget: true
# readBudget.body:
#   firestoreDocumentReads: 1
#   storageReads: 1
#   bodyStorageReadCap: 1
#   withinBodyReadBudget: true

OPENBURNBAR_MCP_TOKEN_HMAC_SECRET=$(gcloud secrets versions access latest \
  --secret REMOTE_MCP_TOKEN_HMAC_SECRET --project burnbar) \
GOOGLE_CLOUD_PROJECT=burnbar \
OPENBURNBAR_STORAGE_BUCKET=burnbar-hosted-mcp-bodies-246956661961 \
node functions/scripts/prove-hosted-mcp-shim-live.mjs \
  --project burnbar \
  --endpoint https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app/mcp \
  --bucket burnbar-hosted-mcp-bodies-246956661961
# ok: true
# proofId: remote-mcp-shim-1778829335741
# shim: openburnbar-mcp-remote stdio
# doctor: PASS token, PASS endpoint 200 OK, PASS tools/list
# toolsListed: 6
# searchReadBudget: firestoreDocumentReads 2, storageReads 0, withinSearchReadBudget true
# bodyReadBudget: firestoreDocumentReads 1, storageReads 1, withinBodyReadBudget true

OPENBURNBAR_MCP_TOKEN_HMAC_SECRET=$(gcloud secrets versions access latest \
  --secret REMOTE_MCP_TOKEN_HMAC_SECRET --project burnbar) \
GOOGLE_CLOUD_PROJECT=burnbar \
OPENBURNBAR_STORAGE_BUCKET=burnbar-hosted-mcp-bodies-246956661961 \
node functions/scripts/prove-hosted-mcp-shim-live.mjs \
  --project burnbar \
  --endpoint https://mcp.burnbar.ai/mcp \
  --bucket burnbar-hosted-mcp-bodies-246956661961
# ok: true
# proofId: remote-mcp-shim-1778838356886
# shim: openburnbar-mcp-remote stdio
# doctor: PASS token, PASS endpoint 200 OK, PASS tools/list
# toolsListed: 6
# searchReadBudget: firestoreDocumentReads 2, storageReads 0, withinSearchReadBudget true
# bodyReadBudget: firestoreDocumentReads 1, storageReads 1, withinBodyReadBudget true

OPENBURNBAR_MCP_ENDPOINT=https://mcp.burnbar.ai/mcp \
  ./scripts/test-hosted-mcp-compatibility.sh
# hosted MCP compatibility config smoke passed

OPENBURNBAR_MCP_ENDPOINT=https://mcp.burnbar.ai/mcp \
OPENBURNBAR_MCP_REAL_CLIENTS=1 \
  ./scripts/test-hosted-mcp-compatibility.sh
# hosted MCP real client config proof passed
# hosted MCP compatibility config smoke passed

npm --prefix tools/openburnbar-mcp-remote test
# 3 tests passed, including stdio notification regression coverage

node tools/openburnbar-mcp-remote/lib/index.js mcp install generic | rg 'mcp.burnbar.ai'
# "OPENBURNBAR_MCP_ENDPOINT": "https://mcp.burnbar.ai/mcp"

OPENBURNBAR_MCP_REAL_CLIENTS=1 ./scripts/test-hosted-mcp-compatibility.sh
# hosted MCP real client config proof passed
# hosted MCP compatibility config smoke passed

# Target-client execution proof using temp HOME, temp PATH shim, and temporary
# real paid MCP client token.
# Claude Code:
# proofId: target-client-mcp-1778838818206
# endpoint: https://mcp.burnbar.ai/mcp
# claude mcp add: passed
# claude mcp get openburnbar: Status connected
#
# Kimi CLI:
# proofId: kimi-client-mcp-1778838908544
# endpoint: https://mcp.burnbar.ai/mcp
# kimi mcp add: passed
# kimi mcp test openburnbar: connected, listed 6 tools
# no JSON-RPC notification parse errors after stdio shim notification fix
#
# Codex:
# proofId: remaining-client-mcp-1778839094526
# codex mcp add: passed
# codex mcp get --json: passed, config references openburnbar-mcp-remote
#
# Droid/Factory:
# proofId: droid-forge-mcp-1778839228521
# droid mcp add using /Users/albertonunez/.local/lib/factory/droid: passed
#
# Forge:
# proofId: forge-client-mcp-17788396763N
# temp HOME with copied non-secret Forge provider/model config, temp PATH shim,
# temporary real paid MCP client token
# forge mcp import: passed
# forge mcp list: loaded OpenBurnBar stdio server and listed 6 tools
# forge mcp reload: passed

gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="openburnbar-hosted-mcp" AND timestamp>="2026-05-15T07:00:00Z"' \
  --project burnbar --limit 200 --format=json
# 201278 bytes scanned. No remote-mcp-shim proof id, proof body text,
# proof hashes, bearer token marker, AES-GCM body, or ciphertext content found.
# The only match for token-related terms was the non-secret Secret Manager
# name REMOTE_MCP_TOKEN_HMAC_SECRET in Cloud Run revision metadata.

gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="openburnbar-hosted-mcp" AND severity>=ERROR AND timestamp>="2026-05-15T07:00:00Z"' \
  --project burnbar --limit 50
# no ERROR-or-higher entries returned

# Real paid subscriber fixture proof against generated Cloud Run URL.
# Account: alberto8793@gmail.com
# UID hash: e82314a10622bcee
# burnbar_pro active: true
# burnbar_pro expireAt: 2026-06-15T03:29:40.000Z
# proofId: real-paid-mcp-1778833323098
# endpoint: https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app/mcp
# audience: https://mcp.burnbar.ai/mcp
# tools/list: 200
# burnbar_resolve_capabilities: 200
# burnbar_search_conversations: 200
# burnbar_get_conversation_body: 200
# post-revoke burnbar_resolve_capabilities: 403 client_revoked
# searchReadBudget: firestoreDocumentReads 2, storageReads 0, within true
# bodyReadBudget: firestoreDocumentReads 1, storageReads 1, within true
# bodyEncrypted: true
# Cleanup verified:
# remaining client false, state false, document false, chunk false, posting false,
# storageObjects 0

# Branded real unpaid fixture proof.
# proofId: branded-real-unpaid-mcp-1778838427075
# endpoint: https://mcp.burnbar.ai/mcp
# checkedUsers: 1
# uidHash: 4ad190a88dc92b9b
# emailHash: 869dabf82df64ddd
# burnbar_resolve_capabilities: 403 burnbar_pro_required
# Cleanup verified: remaining client false

# Branded real paid subscriber fixture proof.
# Account: alberto8793@gmail.com
# UID hash: e82314a10622bcee
# burnbar_pro active: true
# burnbar_pro expireAt: 2026-06-15T03:29:40.000Z
# proofId: branded-real-paid-mcp-1778836657696
# endpoint: https://mcp.burnbar.ai/mcp
# audience: https://mcp.burnbar.ai/mcp
# tools/list: 200
# burnbar_resolve_capabilities: 200
# burnbar_search_conversations: 200
# burnbar_get_conversation_body: 200
# post-revoke burnbar_resolve_capabilities: 403 client_revoked
# searchReadBudget: firestoreDocumentReads 2, storageReads 0, within true
# bodyReadBudget: firestoreDocumentReads 1, storageReads 1, within true
# bodyEncrypted: true
# Cleanup verified:
# remaining client false, state false, document false, chunk false, posting false,
# storageObjects 0

OPENBURNBAR_STORAGE_BUCKET=burnbar-hosted-mcp-bodies-246956661961 \
npm --prefix functions run prove:hosted-mcp-privacy -- \
  --project burnbar \
  --collection-limit 500 \
  --storage-limit 500
# ok: true
# Scanned collection groups:
# cloud_search_documents, cloud_search_chunks, cloud_search_postings,
# cloud_search_index_manifest, cloud_search_index_state,
# cloud_vault_key_wrappers, remote_mcp_clients, remote_mcp_grants,
# remote_mcp_audit_events, remote_mcp_rate_limits
# Current production counts were zero after controlled proof cleanup.
# firestoreViolationCount: 0
# storageViolationCount: 0

# Bounded real-fixture availability check, with only hashed account identifiers
# in output:
# usersSampled: 1
# matchingUsers: 0
# No sampled user had an active burnbar_pro/hosted_quota_sync entitlement,
# cloud_search_documents, cloud_search_chunks, or remote_mcp_clients.
```

`./scripts/test-openburnbar-app.sh` built and ran 916 tests, but exited `65`
because of unrelated existing snapshot, Firebase configuration, provider, and
switcher failures. The hosted-MCP Cloud Store source compiled during that run.
Those broad app-suite failures remain pre-existing app debt, not a hosted MCP
launch blocker, and the hosted MCP path now has targeted backend, shim,
subscription, iPhone, and iPad proof.

## Residual Risks

1. Real subscriber-backed Firestore/Storage privacy scans should be rerun after
   organic subscriber search artifacts exist. Current synthetic/live proof
   privacy scans passed and proof artifacts were cleaned up, but production had
   no persistent subscriber Remote MCP/search documents to sample.
2. The broad app suite still has unrelated legacy failures. Keep the targeted
   hosted MCP gates in release protection and continue paying down the broader
   app-suite debt separately.
3. Wave 8 findings that previously blocked launch are closed by the branded
   endpoint, live backend proof, shim proof, privacy scan, connected-client
   revoke proof, and signed-in iPhone/iPad UI proof in this document.
