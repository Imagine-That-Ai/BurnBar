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
export REMOTE_MCP_TOKEN_HMAC_SECRET=...
./scripts/deploy-hosted-mcp.sh
```

The deploy script builds `services/hosted-mcp`, pushes a Cloud Run image, and
sets the resource audience to `https://mcp.openburnbar.com/mcp`.

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
