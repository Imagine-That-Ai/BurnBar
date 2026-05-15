# Remote MCP Runbook

## Build

```bash
npm ci --prefix services/hosted-mcp
npm --prefix services/hosted-mcp run build
npm --prefix services/hosted-mcp test
```

## Deploy

```bash
export GOOGLE_CLOUD_PROJECT=burnbar
firebase functions:secrets:set REMOTE_MCP_TOKEN_HMAC_SECRET

# Optional: add/rotate the same verifier secret for Cloud Run before deploy.
export REMOTE_MCP_TOKEN_HMAC_SECRET=...
./scripts/deploy-hosted-mcp.sh
```

The deploy script builds `services/hosted-mcp`, pushes a Cloud Run image, and
sets the resource audience to `https://mcp.burnbar.ai/mcp`. The signing
secret must live in Secret Manager as `REMOTE_MCP_TOKEN_HMAC_SECRET`; Cloud
Functions reads it through `defineSecret(...)`, and Cloud Run receives it via
`--set-secrets`, not as a plaintext revision environment variable.

## Domain Mapping

The launch target is `mcp.burnbar.ai`. The older `mcp.openburnbar.com` target is
a future domain-alias option only after the OpenBurnBar domain is verified in
the active Google account. `burnbar.ai` is verified in the active Google account via Search
Console DNS verification, DNS is hosted at Namecheap
(`dns1.registrar-servers.com`, `dns2.registrar-servers.com`), and the current
Cloud Run domain mapping expects:

```text
mcp CNAME ghs.googlehosted.com.
```

```bash
gcloud beta run domain-mappings create \
  --service openburnbar-hosted-mcp \
  --domain mcp.burnbar.ai \
  --region us-central1 \
  --project burnbar
```

After DNS is added, wait until Cloud Run reports `CertificateProvisioned=True`
and `/readyz` responds over the branded hostname.

Current status on 2026-05-15:

```bash
gcloud domains list-user-verified --format='value(id)' | grep '^burnbar.ai$'
# burnbar.ai

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
# Ready=True
# CertificateProvisioned=True
# DomainRoutable=True
```

If the first certificate attempt started before DNS propagated, recreate the
mapping after confirming the CNAME:

```bash
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
```

This was done on 2026-05-15 after DNS was visible. Google provisioned the
managed certificate at `2026-05-15T07:44:11.108493Z`, and
`https://mcp.burnbar.ai/readyz` now returns HTTP 200.

## Live Proof

```bash
node functions/scripts/prove-hosted-mcp-live.mjs \
  --project burnbar \
  --region us-central1 \
  --paid-uid "$OPENBURNBAR_PROOF_PAID_UID" \
  --unpaid-uid "$OPENBURNBAR_PROOF_UNPAID_UID" \
  --endpoint "https://mcp.burnbar.ai/mcp"
```

Set `OPENBURNBAR_MCP_PROOF_TOKEN` for the paid-user tool-list proof. Without it,
the script proves missing-auth denial and exits with a skipped-live-proof code.

## Storage Bucket

Hosted MCP body reads use the Cloud Run environment variable
`OPENBURNBAR_STORAGE_BUCKET`.

Current bucket:

```text
burnbar-hosted-mcp-bodies-246956661961
```

Current serving revision with the bucket configured:

```text
openburnbar-hosted-mcp-00012-dhf
```

The encrypted session upload/download/index Functions are also configured with
the same bucket:

```bash
firebase deploy --project burnbar \
  --only functions:beginEncryptedSessionBlobUpload,functions:getEncryptedSessionBlobDownloadUrl,functions:commitEncryptedSearchIndexBatch

gcloud functions describe beginEncryptedSessionBlobUpload \
  --gen2 --region us-central1 --project burnbar \
  --format='value(serviceConfig.environmentVariables.OPENBURNBAR_STORAGE_BUCKET)'
# burnbar-hosted-mcp-bodies-246956661961
```

## Client Compatibility

Hermetic installer/config smoke:

```bash
./scripts/test-hosted-mcp-compatibility.sh
```

Local real-client config proof, using a temporary `HOME` and leaving real user
client configs untouched:

```bash
OPENBURNBAR_MCP_REAL_CLIENTS=1 ./scripts/test-hosted-mcp-compatibility.sh
```

This proves that the installed Codex, Claude Code, Droid/Factory, Kimi, and
Forge CLIs accept the OpenBurnBar stdio shim configuration. It does not replace
the final real target-client OAuth/search/body compatibility proof.

Branded endpoint config proof:

```bash
OPENBURNBAR_MCP_ENDPOINT=https://mcp.burnbar.ai/mcp \
  ./scripts/test-hosted-mcp-compatibility.sh

OPENBURNBAR_MCP_ENDPOINT=https://mcp.burnbar.ai/mcp \
OPENBURNBAR_MCP_REAL_CLIENTS=1 \
  ./scripts/test-hosted-mcp-compatibility.sh
# hosted MCP real client config proof passed
# hosted MCP compatibility config smoke passed
```

The shim and generated JSON installers now default to:

```text
https://mcp.burnbar.ai/mcp
```

Run this after changing defaults:

```bash
npm --prefix tools/openburnbar-mcp-remote test
OPENBURNBAR_MCP_REAL_CLIENTS=1 ./scripts/test-hosted-mcp-compatibility.sh
```

Target-client execution proof captured so far:

- Claude Code: temp HOME + temp PATH shim, `claude mcp get openburnbar`
  reported connected against `https://mcp.burnbar.ai/mcp`.
- Kimi CLI: temp HOME + temp PATH shim, `kimi mcp test openburnbar` connected
  and listed all six OpenBurnBar tools.
- Codex: temp HOME + temp PATH shim, `codex mcp add` and
  `codex mcp get --json` passed.
- Droid/Factory: temp HOME + temp PATH shim, real Factory `droid mcp add`
  passed.
- Forge: temp HOME with copied non-secret Forge provider/model config, temp PATH
  shim, and temporary real MCP token/client; `forge mcp import`, `forge mcp
  list`, and `forge mcp reload` passed, with `list` reporting 6 OpenBurnBar
  tools.

Live stdio shim proof:

```bash
OPENBURNBAR_MCP_TOKEN_HMAC_SECRET=$(gcloud secrets versions access latest \
  --secret REMOTE_MCP_TOKEN_HMAC_SECRET --project burnbar) \
GOOGLE_CLOUD_PROJECT=burnbar \
OPENBURNBAR_STORAGE_BUCKET=burnbar-hosted-mcp-bodies-246956661961 \
node functions/scripts/prove-hosted-mcp-shim-live.mjs \
  --project burnbar \
  --endpoint https://openburnbar-hosted-mcp-cjrjb5ckqq-uc.a.run.app/mcp \
  --bucket burnbar-hosted-mcp-bodies-246956661961
# proofId remote-mcp-shim-1778829335741 passed doctor, tools/list, search, and body fetch.

node functions/scripts/prove-hosted-mcp-shim-live.mjs \
  --project burnbar \
  --endpoint https://mcp.burnbar.ai/mcp \
  --bucket burnbar-hosted-mcp-bodies-246956661961
# proofId remote-mcp-shim-1778838356886 passed doctor, tools/list, search, and body fetch.
# searchReadBudget: firestoreDocumentReads 2, storageReads 0
# bodyReadBudget: firestoreDocumentReads 1, storageReads 1
```

## Monitor

Configured Cloud Monitoring policies:

- `OpenBurnBar Hosted MCP 5xx spike`
- `OpenBurnBar Hosted MCP 429 spike`
- `OpenBurnBar Hosted MCP auth denial spike`
- `OpenBurnBar Hosted MCP p95 latency spike`
- `OpenBurnBar Hosted MCP instance pressure`
- `OpenBurnBar Firestore read spike`

They are backed by these user log-based metrics:

- `logging.googleapis.com/user/openburnbar_hosted_mcp_5xx`
- `logging.googleapis.com/user/openburnbar_hosted_mcp_429`
- `logging.googleapis.com/user/openburnbar_hosted_mcp_auth_denial`

The hosted MCP p95 latency and instance-pressure policies use Cloud Run metrics
scoped to `resource.labels.service_name="openburnbar-hosted-mcp"`. The
Firestore read policy is project-level Firestore read-spike coverage; use
per-request audit events and live proof output for MCP-specific read-budget
verification.

Configured Cloud Monitoring dashboard:

- `OpenBurnBar Hosted MCP Cost and Capacity`
  (`projects/246956661961/dashboards/4df51728-d486-44a0-a11f-bc3dc0eeea2b`)

The dashboard separates Cloud Run request rate, Cloud Run p95 latency, Cloud Run
instance count, Firestore document reads, Cloud Storage API requests, Cloud KMS
requests, and Redis memory pressure.

Search/body proof:

```bash
gcloud builds log 5f8a5d00-0255-4a14-8f54-5c6d4b010269 \
  --project burnbar --region global
# 1000 documents, 100 matching candidates, 20 iterations
# search p50 267 ms, p95 471 ms
# body p50 304 ms, p95 534 ms
# readBudget.search.firestoreDocumentReads 50
# readBudget.search.storageReads 0
# readBudget.body.firestoreDocumentReads 1
# readBudget.body.storageReads 1
# readBudget.search.withinSearchReadBudget true
# readBudget.body.withinBodyReadBudget true
```

Firestore/Storage privacy scan:

```bash
OPENBURNBAR_STORAGE_BUCKET=burnbar-hosted-mcp-bodies-246956661961 \
npm --prefix functions run prove:hosted-mcp-privacy -- \
  --project burnbar \
  --collection-limit 500 \
  --storage-limit 500
# ok true
# Scanned collection groups:
# cloud_search_documents, cloud_search_chunks, cloud_search_postings,
# cloud_search_index_manifest, cloud_search_index_state,
# cloud_vault_key_wrappers, remote_mcp_clients, remote_mcp_grants,
# remote_mcp_audit_events, remote_mcp_rate_limits
# Current production counts were zero after controlled proof cleanup.
# firestoreViolationCount 0
# storageViolationCount 0
```

Still required before launch:

- Prove authenticated real target-client flows against the branded endpoint.

## Rollback

```bash
gcloud run revisions list --service openburnbar-hosted-mcp --region us-central1
gcloud run services update-traffic openburnbar-hosted-mcp \
  --region us-central1 \
  --to-revisions REVISION=100
```

If auth or privacy behavior is suspect, revoke the Cloud Run service account's
Firestore/Storage permissions before debugging.

Last rehearsal: 2026-05-15. Traffic was moved from
`openburnbar-hosted-mcp-00005-ndq` to prior ready revision
`openburnbar-hosted-mcp-00004-xf4`, `/readyz` returned healthy, and traffic was
restored to `openburnbar-hosted-mcp-00005-ndq` at 100% with `/readyz` healthy.
Current serving revision after the body-bucket deploy is
`openburnbar-hosted-mcp-00012-dhf`.
