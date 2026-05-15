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

## Monitor

Alert on:

- 401/403 spikes.
- 429 spikes.
- p95 latency above 900 ms for search.
- p95 body fetch above 2.5 s.
- 5xx spikes.
- Cloud Run instance pressure.
- Firestore read spikes from hosted MCP service account.

## Rollback

```bash
gcloud run revisions list --service openburnbar-hosted-mcp --region us-central1
gcloud run services update-traffic openburnbar-hosted-mcp \
  --region us-central1 \
  --to-revisions REVISION=100
```

If auth or privacy behavior is suspect, revoke the Cloud Run service account's
Firestore/Storage permissions before debugging.
