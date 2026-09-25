# OpenBurnBar Cloud Functions

Firebase Functions v2 backend for OpenBurnBar. Handles provider credential vaulting, quota refresh, and canonical usage rollup computation.

## Architecture

```
iOS → Cloud Functions → Firestore / Secret Manager / Provider APIs
  ↑
Mac → Firestore (usage, quota snapshots)
```

## Deploy codebases (3.5)

Four independently deployable codebases (`firebase.json` `functions[]`):
`identity` (`functions-identity/`), `sync` (`functions-sync/`), `media`
(`functions-media`), `admin` (`functions/`, this directory). Build all with
`./scripts/build-functions-all.sh`; deploy one with
`firebase deploy --only functions:identity` (etc.).

Cold-start proxy measured 2026-09-25 (fresh `node`, `require()` built
`lib/index.js`, second run to skip disk-cache noise; not Cloud Run
wall-clock, but comparable across codebases):

| Codebase | `lib/` size | require time | modules loaded |
|---|---|---:|---:|
| identity | 1.9 MB | ~1.4 s | 2031 |
| sync | 2.0 MB | ~1.0 s | 1446 |
| media | 0.8 MB | ~1.0 s | 1423 |
| admin | 1.6 MB | ~1.0 s | 1422 |

Identity's extra ~600 modules are passkey/WebAuthn-only (`@simplewebauthn`,
`asn1js`, `@peculiar`, …) — sync/media/admin cold starts do not pay for
them, which is the isolation the split exists to provide. Re-measure
before growing a codebase's dependency set:

```bash
for cb in functions-identity functions-sync functions-media functions; do
  node -e "const t0=process.hrtime.bigint();require('./$cb/lib/index.js');console.log('$cb',Number(process.hrtime.bigint()-t0)/1e6+'ms',Object.keys(require.cache).length+'modules')" 2>/dev/null
done
```

## Setup

1. **Install dependencies**
   ```bash
   cd functions
   npm install
   ```

2. **Configure runtime params and secrets**
   ```bash
   firebase functions:secrets:set HOSTED_QUOTA_RUNNER_TOKEN

   cat > .env.PROJECT_ID <<'EOF'
   KMS_KEY_NAME=projects/PROJECT/locations/LOCATION/keyRings/RING/cryptoKeys/KEY
   HOSTED_QUOTA_RUNNER_URL=https://openburnbar-quota-runner-PROJECT.REGION.run.app
   HOSTED_QUOTA_RUNNER_ALLOWED_HOSTS=openburnbar-quota-runner-PROJECT.REGION.run.app
   HOSTED_QUOTA_PRODUCT_ID=com.openburnbar.hostedQuotaSync.cloud.monthly
   EOF
   ```

3. **Build**
   ```bash
   npm run build
   ```

4. **Deploy**
   ```bash
   firebase deploy --only functions
   ```

5. **Emulator (local dev)**
   ```bash
   npm run serve
   ```

## Functions

### Callable (Auth + App Check required)

| Function | Purpose |
|---|---|
| `connectProviderCredential` | Validate credential, encrypt via KMS, store in Secret Manager, write metadata |
| `deleteProviderCredential` | Destroy secret, mark disconnected, stale-mark snapshot |
| `refreshProviderQuota` | On-demand quota refresh with rate limiting |
| `rebuildUsageRollups` | On-demand rollup rebuild for signed-in user |

### Background

| Function | Trigger | Purpose |
|---|---|---|
| `onUsageWritten` | Firestore onWrite `users/{uid}/usage/{doc}` | Mark rollup job dirty |
| `rebuildRollups` | Schedule every 5 min | Batch rebuild dirty rollups |
| `refreshAllProviderQuotas` | Schedule every 15 min | Batch refresh active connections |

## Provider Support

| Provider | Credential Kind | Backend Refresh | Warning |
|---|---|---|---|
| MiniMax | API token | Yes | — |
| Z.ai | API token | Yes | — |
| Factory | Bearer / Session | Yes | Session credentials expire |
| Cursor | Cookie / Session | Best-effort | Low confidence, short TTL |
| Claude Code | — | No (desktop-only) | — |
| Codex | — | No (desktop-only) | — |

## Security

- All secrets encrypted with Cloud KMS envelope encryption (AES-256-GCM + KMS-protected DEK).
- Firestore stores only metadata and secret version resource names.
- Callable functions enforce Firebase Auth UID + App Check.
- Provider allowlist prevents arbitrary secret storage.
