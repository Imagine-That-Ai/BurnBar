# Hosted Remote MCP Completion Audit

Date: 2026-05-15

Objective audited:
`docs/plans/HOSTED_REMOTE_MCP_MULTI_AGENT_SPRINT_PLAN.md` end-to-end implementation.

Verdict: **hold**. The source implementation is present, Cloud Run is deployed
on its generated `run.app` URL, the grant/revoke Functions are deployed,
controlled live paid/unpaid/revoked/cross-tenant proof passed, `burnbar.ai`
ownership is verified in Google, and `mcp.burnbar.ai` DNS is configured. The
production definition of done is still not met because the Google-managed
certificate for `mcp.burnbar.ai`, branded-endpoint subscriber proof, and real
client compatibility proof are still missing.

## Prompt-To-Artifact Checklist

| Requirement | Artifact / Evidence | Status |
| --- | --- | --- |
| Standards-first Streamable HTTP endpoint at `https://mcp.openburnbar.com/mcp` | `services/hosted-mcp/src/server.ts`, `src/mcp.ts`, `src/oauthMetadata.ts` implement `/mcp`, protocol handlers, metadata, errors, origin checks | Cloud Run URL deployed; branded domain absent |
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
| Installer output for Codex, Claude Code, Droid/Factory, Kimi, Forge, generic | `tools/openburnbar-mcp-remote/src/installers.ts`, `src/installers.test.ts`, `scripts/test-hosted-mcp-compatibility.sh`, `functions/scripts/prove-hosted-mcp-shim-live.mjs` | Hermetic verification plus temp-profile real CLI config proof passed; live stdio shim proof passed for tools/list, search, and body fetch; target-client authenticated UI flows remain pending |
| Doctor command | `tools/openburnbar-mcp-remote/src/doctor.ts`, `functions/scripts/prove-hosted-mcp-shim-live.mjs` | Live doctor proof passed with temporary MCP token: token found, endpoint `200 OK`, and `tools/list` passed |
| App UX for setup/status/revoke | `OpenBurnBarMobile/Views/Store/CloudStoreView.swift`, `AgentLens/Views/Settings/CloudStoreSettingsView.swift`, `android/app/src/main/java/com/openburnbar/ui/store/CloudStoreView.kt`, and `android/app/src/main/java/com/openburnbar/data/stores/RemoteMcpClientStore.kt` show setup/status copy, list `remote_mcp_clients`, display scopes/last-used/decrypt mode/status, and call `revokeRemoteMcpClient` | iOS/iPadOS, macOS, and Android member UI implemented; Android `assembleDebug` passed; macOS fresh-DerivedData build passed; iOS source compiled with warnings before unrelated widget gate failure |
| Production deploy | `scripts/deploy-hosted-mcp.sh` deployed `openburnbar-hosted-mcp-00011-zqb`; Cloud Run env update deployed `openburnbar-hosted-mcp-00012-dhf`; Storage bucket `burnbar-hosted-mcp-bodies-246956661961`; encrypted-session Functions callables redeployed with `OPENBURNBAR_STORAGE_BUCKET`; image digest `sha256:b13876c48978972c19fe253dc2a6787c4e1441291e3763d6c7e616edf30d1495` | Cloud Run deployed at generated URL with 100% traffic and body bucket configured; upload/download/search-index callables are active with the same bucket |
| Domain `mcp.openburnbar.com` or fallback `mcp.burnbar.ai` | Google Search Console ownership verification; Namecheap DNS; Cloud Run domain mapping; `dig +short CNAME mcp.burnbar.ai @1.1.1.1`; `dig +short CNAME mcp.burnbar.ai @8.8.8.8`; `dig +short CNAME mcp.burnbar.ai @9.9.9.9`; `gcloud beta run domain-mappings describe ...` | `burnbar.ai` ownership verified; `mcp.burnbar.ai CNAME ghs.googlehosted.com.` resolves publicly from Cloudflare, Google, and Quad9; Cloud Run mapping exists and is domain-routable; managed certificate remains `CertificatePending`, so branded HTTPS proof is still blocked |
| Live paid/unpaid/revoked/cross-tenant proof | `functions/scripts/prove-hosted-mcp-live.mjs`; controlled temporary Firestore proof users against generated Cloud Run URL; real paid fixture `alberto8793@gmail.com` against generated Cloud Run URL | Controlled paid/unpaid/revoked/cross-tenant proof passed; real paid subscriber fixture proved active entitlement, tools/list, capabilities, search, encrypted body fetch, and revoke denial on generated URL; branded-endpoint subscriber proof still missing |
| Alerts/logging/rollback/cost dashboard | `docs/REMOTE_MCP_RUNBOOK.md`, `functions/scripts/prove-hosted-mcp-privacy-scan.mjs`, structured logging in service; Cloud Run logs scanned after live proof window; Monitoring policies `OpenBurnBar Hosted MCP 5xx spike`, `OpenBurnBar Hosted MCP 429 spike`, `OpenBurnBar Hosted MCP auth denial spike`, `OpenBurnBar Hosted MCP p95 latency spike`, `OpenBurnBar Hosted MCP instance pressure`, and project-level `OpenBurnBar Firestore read spike`; dashboard `OpenBurnBar Hosted MCP Cost and Capacity`; rollback rehearsal from `00005-ndq` to `00004-xf4` and back | No obvious plaintext/token leakage in sampled Cloud Run logs; production Firestore/Storage privacy scan passed with zero violations, but current Remote MCP/search collections were empty after controlled proof cleanup; hosted-MCP 5xx/429/auth-denial/latency/instance alerts exist; project-level Firestore read alert exists; cost/capacity dashboard exists; rollback rehearsal passed |
| Multi-agent audit reports | `docs/plans/HOSTED_REMOTE_MCP_WAVE8_AUDIT_REPORT.md`, `docs/plans/HOSTED_REMOTE_MCP_WAVE8_SIGNED_STREAM_REPORTS.md` | Every required stream has a signed report and prioritized findings; reports recommend hold until branded HTTPS, real subscriber proof, and real client proof are complete |

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

Failed or blocked:

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
# DomainRoutable=True
# Ready=Unknown, reason=CertificatePending
# CertificateProvisioned=Unknown, reason=CertificatePending
# resourceRecords: mcp CNAME ghs.googlehosted.com.

curl -i --max-time 15 https://mcp.burnbar.ai/readyz
# blocked while Google-managed certificate is pending:
# LibreSSL SSL_connect: SSL_ERROR_SYSCALL

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
# Recreated after DNS propagation. Fresh mapping is DomainRoutable=True,
# CertificateProvisioned=Unknown, and retry interval is 01:00.
# http://mcp.burnbar.ai/readyz reaches Google Frontend and redirects to HTTPS.
# Retry at 2026-05-15T07:25:09Z still reported CertificatePending and set the
# next polling interval to 01:00.

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
# audience: https://mcp.openburnbar.com/mcp
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
switcher failures. The hosted-MCP Cloud Store source compiled during that run,
but the full app gate is not green.

## Remaining Work

1. Wait for Cloud Run's Google-managed certificate for `mcp.burnbar.ai`, then
   prove `https://mcp.burnbar.ai/readyz` and `https://mcp.burnbar.ai/mcp`.
2. Rerun subscriber proof on the final branded endpoint after HTTPS certificate
   issuance. Real paid subscriber proof already passed on the generated URL.
3. Run final real client compatibility for Codex, Claude Code, Droid/Factory,
   Kimi, Forge, and generic MCP against the branded endpoint with OAuth,
   tools/list, search, and body fetch. Temp-profile local config proof now
   passes but does not prove authenticated live tool use.
4. Add real subscriber-backed Firestore/Storage privacy scan evidence once real
   subscriber search artifacts exist; current production scan passed but had no
   Remote MCP/search documents to inspect after proof cleanup.
5. Fix or explicitly accept every remaining Wave 8 finding after branded HTTPS,
   real subscriber proof, and real client proof are available.
