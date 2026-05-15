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
sets the resource audience to `https://mcp.openburnbar.com/mcp`. The signing
secret must live in Secret Manager as `REMOTE_MCP_TOKEN_HMAC_SECRET`; Cloud
Functions reads it through `defineSecret(...)`, and Cloud Run receives it via
`--set-secrets`, not as a plaintext revision environment variable.

## Domain Mapping

The launch target is `mcp.openburnbar.com`. If the OpenBurnBar domain is not
verified in the active Google account, `mcp.burnbar.ai` is an acceptable branded
fallback once `burnbar.ai` is verified.

```bash
gcloud domains verify burnbar.ai
gcloud beta run domain-mappings create \
  --service openburnbar-hosted-mcp \
  --domain mcp.burnbar.ai \
  --region us-central1 \
  --project burnbar
```

After Cloud Run prints the required DNS records, add them at the domain's DNS
host and wait until `/readyz` responds over the branded hostname.

## Live Proof

```bash
node functions/scripts/prove-hosted-mcp-live.mjs \
  --project burnbar \
  --region us-central1 \
  --paid-uid "$OPENBURNBAR_PROOF_PAID_UID" \
  --unpaid-uid "$OPENBURNBAR_PROOF_UNPAID_UID" \
  --endpoint "https://mcp.openburnbar.com/mcp"
```

Set `OPENBURNBAR_MCP_PROOF_TOKEN` for the paid-user tool-list proof. Without it,
the script proves missing-auth denial and exits with a skipped-live-proof code.

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
the final branded-endpoint OAuth/search/body compatibility proof.

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

Still required before launch:

- MCP-specific Firestore read-budget proof for representative search and body
  fetches.
- Cost dashboard separating Cloud Run, Firestore, Storage, KMS, and Redis.

## Rollback

```bash
gcloud run revisions list --service openburnbar-hosted-mcp --region us-central1
gcloud run services update-traffic openburnbar-hosted-mcp \
  --region us-central1 \
  --to-revisions REVISION=100
```

If auth or privacy behavior is suspect, revoke the Cloud Run service account's
Firestore/Storage permissions before debugging.
