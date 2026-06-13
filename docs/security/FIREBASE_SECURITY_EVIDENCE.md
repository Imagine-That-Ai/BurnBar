# Firebase Security Evidence

`scripts/ops/collect-firebase-security-evidence.mjs` collects a read-only JSON
evidence bundle for production Firebase/GCP security posture.

The collector records:

- Firebase project identity and active `gcloud`/Firebase auth context.
- Firebase App Check enforcement for Firestore and Cloud Storage.
- Firestore rules hash, Firestore index hash, and Storage rules hashes compared
  with the repo files.
- Project IAM policy bindings.
- Cloud Functions Gen 2 inventory for configured regions.
- Cloud Storage bucket security posture and bucket IAM.
- Secret Manager secret inventory and per-secret IAM policies.
- Cloud KMS keyring/key inventory and key IAM policies for configured locations.

It does **not** read Secret Manager payloads, print OAuth access tokens, or treat
Firebase web API keys as secrets. Sensitive fields in command output are redacted
before the JSON artifact is written.

Run locally:

```bash
FIREBASE_PROJECT=burnbar \
FUNCTIONS_REGION=us-central1 \
node scripts/ops/collect-firebase-security-evidence.mjs --strict
```

The production `ops-plane-verify` workflow also runs this collector and uploads
`firebase-security-evidence.json` with the verification summary artifact.
