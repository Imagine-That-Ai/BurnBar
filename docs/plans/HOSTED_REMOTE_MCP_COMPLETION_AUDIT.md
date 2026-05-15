# Hosted Remote MCP Completion Audit

Date: 2026-05-15

Objective audited:
`docs/plans/HOSTED_REMOTE_MCP_MULTI_AGENT_SPRINT_PLAN.md` end-to-end implementation.

Verdict: **hold**. The source implementation is present, Cloud Run is deployed
on its generated `run.app` URL, and the grant/revoke Functions are deployed, but
the production definition of done is not met because the branded DNS/domain,
live paid/unpaid/revoked/cross-tenant proof, real client compatibility proof,
and signed audit reports are still missing.

## Prompt-To-Artifact Checklist

| Requirement | Artifact / Evidence | Status |
| --- | --- | --- |
| Standards-first Streamable HTTP endpoint at `https://mcp.openburnbar.com/mcp` | `services/hosted-mcp/src/server.ts`, `src/mcp.ts`, `src/oauthMetadata.ts` implement `/mcp`, protocol handlers, metadata, errors, origin checks | Cloud Run URL deployed; branded domain absent |
| MCP methods: `initialize`, `tools/list`, `tools/call`, `resources/list`, `resources/read` | `services/hosted-mcp/src/mcp.ts`, `src/toolRegistry.ts`, `src/resources.ts`; local tests pass | Locally verified |
| Missing auth returns `401`; invalid origin returns `403`; bounded oversized input | `scripts/test-hosted-mcp-security.sh`; local run passed in implementation pass | Locally verified only |
| OpenBurnBar Pro paywall via `users/{uid}/entitlements/burnbar_pro` | `functions/src/index.ts`, `functions/src/remoteMcpOAuth.ts`, `services/hosted-mcp/src/entitlements.ts` | Source present; live paid/unpaid proof missing |
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
| App UX for setup/status/revoke | `OpenBurnBarMobile/Views/Store/CloudStoreView.swift` shows setup/status copy | Partial: setup/status present; live client list/revoke UI not complete |
| Production deploy | `scripts/deploy-hosted-mcp.sh` deployed `openburnbar-hosted-mcp-00001-cvv` | Cloud Run deployed at generated URL |
| Domain `mcp.openburnbar.com` or fallback `mcp.burnbar.ai` | `curl https://mcp.openburnbar.com/readyz`; `gcloud beta run domain-mappings create ...`; `gcloud domains list-user-verified` | Fails DNS resolution; both domain mappings blocked because neither `openburnbar.com` nor `burnbar.ai` is verified in this Google account |
| Live paid/unpaid/revoked/cross-tenant proof | `functions/scripts/prove-hosted-mcp-live.mjs` | Script present; cannot complete without endpoint/proof tokens/accounts |
| Alerts/logging/rollback | `docs/REMOTE_MCP_RUNBOOK.md`, structured logging in service | Docs/source present; live alerts not verified |
| Multi-agent audit reports | Required by Wave 8 | Missing |

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
```

Failed or blocked:

```bash
gcloud secrets describe REMOTE_MCP_TOKEN_HMAC_SECRET --project burnbar
# Secret exists; version 1 was created during deploy.

gcloud run services describe openburnbar-hosted-mcp --region us-central1 --project burnbar
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
# missingAuthStatus: 401; skippedLivePaidProof: true because OPENBURNBAR_MCP_PROOF_TOKEN is not set

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
2. Run live paid, unpaid, revoked-client, and cross-tenant proof.
3. Run real client compatibility for Codex, Claude Code, Droid/Factory, Kimi,
   Forge, and generic MCP.
4. Add real connected-client list/revoke UI or explicitly scope it out with a
   follow-up owner/date.
5. Verify Cloud logs and Firestore contain no plaintext query/session/body/token
   leakage.
6. Create/rehearse alerts and rollback.
7. Produce Wave 8 audit reports and fix or explicitly accept every finding.
