# Remote MCP Runbook

## Build

```bash
npm ci --prefix services/hosted-mcp
npm --prefix services/hosted-mcp run build
npm --prefix services/hosted-mcp test
```

## Deploy

Normal production deploys run through GitHub Actions:

1. Create or choose a `v*` release tag.
2. Run **Deploy Cloud Run Services** (`.github/workflows/deploy-cloud-run.yml`)
   from that tag, or let the tag push trigger it.

The workflow builds and tests `services/hosted-mcp`, performs a Docker build
smoke from the repository-root context, then stages a bounded deploy artifact
before any production credentials are available. The credentialed deploy job
does not check out repository code: it downloads the verified artifact,
authenticates to Google Cloud with OIDC workload identity federation, verifies
the deploy service account has the required Cloud Run/Cloud Build IAM, read-only
Secret Manager metadata/payload access, and no Secret Manager write-capable
role, captures the currently serving revision,
deploys `openburnbar-hosted-mcp`, reads the service back, and auto-rolls back to
the previous ready revision if deploy or readback fails. It also preserves the
live `OPENBURNBAR_STORAGE_BUCKET` instead of hard-coding it. CI deploys bind
existing signer secrets only; signer rotations remain an out-of-band operator
step.

Use this local path only for operator break-glass deploys or manual rehearsal:

```bash
export GOOGLE_CLOUD_PROJECT=burnbar
firebase functions:secrets:set REMOTE_MCP_TOKEN_HMAC_SECRET # legacy transition only
gcloud secrets create MCP_CURSOR_HMAC_SECRET --replication-policy=automatic --project burnbar # once

# Production token signing should use Ed25519:
# - Functions grant issuer / hosted refresh signer: REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64
# - Cloud Run verifier: MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64
# Values are base64-encoded PEM. If MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64 is set,
# Cloud Run refuses legacy HMAC access tokens unless MCP_ALLOW_LEGACY_HMAC_TOKENS=true.
export REMOTE_MCP_TOKEN_HMAC_SECRET=...
export REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64=...
export MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64=...
export MCP_CURSOR_HMAC_SECRET=... # real pagination-cursor HMAC key; not dev-secret/dev-cursor-secret
export OPENBURNBAR_HOSTED_MCP_ALLOW_SECRET_UPSERT=true # only for intentional key rotation
./scripts/deploy-hosted-mcp.sh
```

Hermes realtime relay (separate sidecar): [`scripts/deploy-hermes-relay.sh`](../scripts/deploy-hermes-relay.sh) — set `HERMES_RELAY_URL` and it gates on `/healthz` after your Cloud Run deploy.

The deploy script builds `services/hosted-mcp`, pushes a Cloud Run image, gates on
`/readyz` (override with `MCP_HEALTH_PATH` only for a custom health path), and
sets the resource audience to `https://mcp.burnbar.ai/mcp` and issuer to
`https://mcp.burnbar.ai`. HMAC signing is a legacy transition path; Ed25519
signing is the production target so the resource server can verify with a
public key and refuse shared-secret tokens by default. The script refuses to
upsert signer secrets unless `OPENBURNBAR_HOSTED_MCP_ALLOW_SECRET_UPSERT=true`
is set, so normal production deploys cannot rotate token-signing material as an
accidental side effect.

### Scheduled deploy lane-health exit paths

The scheduled/manual `.github/workflows/deploy-lane-health.yml` observes the latest
non-dry-run Cloud Run release and probes `https://mcp.burnbar.ai/readyz`. It is
strictly read-only: it does not dispatch a release, mutate Cloud Run traffic,
or retry a failed tag workflow. The uploaded `deploy-lane-health.json` is the
scoreboard and includes the deploy conclusion, probe result, run URL, and
consecutive-red count.

- A failed/cancelled/skipped deploy, a missing deploy run, a GitHub API error,
  or a non-200/not-ready probe is red. A deploy conclusion of `failure` is
  retained as a deploy/product failure; API, missing-run, and probe failures
  carry infrastructure reason codes.
- Red or unavailable data exits non-zero and opens/updates the `deploy-health`
  issue. The shared ops action deduplicates the first page and re-pages an
  unblocked P0 once at the seven-day tier; a configured named blocker suppresses
  automated escalation without turning the lane green.
- **Human queue exit:** the release owner records the blocker, accountable
  owner, and expiry in the issue, then uses the main-only approved
  `existing_tag_retry` control or pins traffic to the previous ready revision.
  Do not rerun a tag-bound workflow from the old tag, manually change traffic
  without recording the revision, or close the issue before `/readyz` and
  deployment readback are green.

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
  and listed all OpenBurnBar tools available at that release. The 2026-05-15
  proof listed six tools; BurnBar Resume raises the expected hosted count to
  eight after deploy.
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
scripts/ops/rollback-revision.sh openburnbar-hosted-mcp \
  --region us-central1 \
  --project burnbar

scripts/ops/rollback-revision.sh openburnbar-hosted-mcp REVISION \
  --region us-central1 \
  --project burnbar \
  --yes
```

The deploy workflow captures the previous ready revision before shifting
traffic and runs the equivalent explicit Cloud Run `update-traffic` rollback
automatically if the deploy or post-deploy readback fails.

If auth or privacy behavior is suspect, revoke the Cloud Run service account's
Firestore/Storage permissions before debugging.

Last rehearsal: 2026-05-15. Traffic was moved from
`openburnbar-hosted-mcp-00005-ndq` to prior ready revision
`openburnbar-hosted-mcp-00004-xf4`, `/readyz` returned healthy, and traffic was
restored to `openburnbar-hosted-mcp-00005-ndq` at 100% with `/readyz` healthy.
Current serving revision after the body-bucket deploy is
`openburnbar-hosted-mcp-00012-dhf`.
