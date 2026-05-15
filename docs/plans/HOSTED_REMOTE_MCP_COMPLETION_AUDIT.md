# Hosted Remote MCP Completion Audit

Date: 2026-05-15

Objective audited:
`docs/plans/HOSTED_REMOTE_MCP_MULTI_AGENT_SPRINT_PLAN.md` end-to-end implementation.

Verdict: **hold**. The source implementation is present, Cloud Run is deployed
on its generated `run.app` URL, the grant/revoke Functions are deployed, and a
controlled live paid/unpaid/revoked/cross-tenant proof passed. The production
definition of done is still not met because the branded DNS/domain, real
subscriber proof, real client compatibility proof, and signed audit reports are
still missing.

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
| Search does zero Storage reads and uses manifest/postings | `services/hosted-mcp/src/search.ts`, `src/resources.ts`, `functions/src/cloudSearchCore.ts` | Source present; large/live corpus perf proof missing |
| Deny-by-default tool registry | `services/hosted-mcp/src/toolRegistry.ts` declares scopes, entitlement, input/output caps, cost class, rate bucket, audit kind, redaction policy | Source present |
| Required tools: search, body, index status, facets, recent usage, capabilities | `services/hosted-mcp/src/toolRegistry.ts` | Source present |
| Firestore data additions and rules | `firestore.rules`, `firestore.indexes.json`, `functions/scripts/test-firestore-rules.mjs` | Rules tests passed |
| Local shim for stdio clients and local decrypt | `tools/openburnbar-mcp-remote/src/*` | Tests/lint passed |
| Installer output for Codex, Claude Code, Droid/Factory, Kimi, Forge, generic | `tools/openburnbar-mcp-remote/src/installers.ts`, `src/installers.test.ts`, `scripts/test-hosted-mcp-compatibility.sh` | Hermetic verification only |
| Doctor command | `tools/openburnbar-mcp-remote/src/doctor.ts` | Source present; live doctor proof missing |
| App UX for setup/status/revoke | `OpenBurnBarMobile/Views/Store/CloudStoreView.swift` shows setup/status copy, lists `remote_mcp_clients`, displays scopes/last-used/decrypt mode/status, and calls `revokeRemoteMcpClient`; targeted iOS build passed | iOS/iPadOS member UI implemented; macOS/Android parity not verified |
| Production deploy | `scripts/deploy-hosted-mcp.sh` deployed `openburnbar-hosted-mcp-00004-xf4` from commit `04f30b8f0` | Cloud Run deployed at generated URL |
| Domain `mcp.openburnbar.com` or fallback `mcp.burnbar.ai` | `curl https://mcp.openburnbar.com/readyz`; `gcloud beta run domain-mappings create ...`; `gcloud domains list-user-verified` | Fails DNS resolution; both domain mappings blocked because neither `openburnbar.com` nor `burnbar.ai` is verified in this Google account |
| Live paid/unpaid/revoked/cross-tenant proof | `functions/scripts/prove-hosted-mcp-live.mjs`; controlled temporary Firestore proof users against generated Cloud Run URL | Controlled paid/unpaid/revoked/cross-tenant proof passed; real subscriber proof still missing |
| Alerts/logging/rollback | `docs/REMOTE_MCP_RUNBOOK.md`, structured logging in service; Cloud Run logs scanned after live proof window; Monitoring policies `OpenBurnBar Hosted MCP 5xx spike`, `OpenBurnBar Hosted MCP 429 spike`, `OpenBurnBar Hosted MCP auth denial spike`, `OpenBurnBar Hosted MCP p95 latency spike`, `OpenBurnBar Hosted MCP instance pressure`, and project-level `OpenBurnBar Firestore read spike` | No obvious plaintext/token leakage in sampled Cloud Run logs; hosted-MCP 5xx/429/auth-denial/latency/instance alerts exist; project-level Firestore read alert exists; MCP-specific read-budget proof and rollback rehearsal still missing |
| Multi-agent audit reports | `docs/plans/HOSTED_REMOTE_MCP_WAVE8_AUDIT_REPORT.md` | Primary-integrator role audit exists and recommends hold; independent multi-agent reviewer reports are not separately produced |

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
./scripts/test-openburnbar-swift.sh
xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Failed or blocked:

```bash
gcloud secrets describe REMOTE_MCP_TOKEN_HMAC_SECRET --project burnbar
# Secret exists; version 1 was created during deploy.

gcloud run services describe openburnbar-hosted-mcp --region us-central1 --project burnbar
# latestReadyRevisionName: openburnbar-hosted-mcp-00004-xf4
# traffic: 100
# Service URL: https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app

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
# proofId: remote-mcp-proof-1778822270407
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

gcloud beta run domain-mappings create \
  --service openburnbar-hosted-mcp \
  --domain mcp.burnbar.ai \
  --region us-central1 \
  --project burnbar
# blocked: burnbar.ai is not verified for the active Google account

gcloud domains list-user-verified
# hormigadormida.com
# imagine-that.ai
```

`./scripts/test-openburnbar-app.sh` built and ran 916 tests, but exited `65`
because of unrelated existing snapshot, Firebase configuration, provider, and
switcher failures. The hosted-MCP Cloud Store source compiled during that run,
but the full app gate is not green.

## Remaining Work

1. Verify ownership of `openburnbar.com` or `burnbar.ai` in the `burnbar` Google
   account, create the Cloud Run domain mapping, and update DNS.
2. Run real subscriber proof on the final branded endpoint.
3. Run real client compatibility for Codex, Claude Code, Droid/Factory, Kimi,
   Forge, and generic MCP.
4. Add or verify macOS and Android parity for connected-client list/revoke UI,
   or explicitly scope those surfaces out with a follow-up owner/date.
5. Verify Firestore contains no plaintext query/session/body/token leakage.
6. Add MCP-specific Firestore read-budget proof, cost dashboard coverage, and
   rehearse rollback.
7. Produce independent Wave 8 reviewer reports if required beyond the
   primary-integrator role audit, then fix or explicitly accept every finding.
