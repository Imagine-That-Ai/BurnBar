# OpenTimestamps verifier service

Small Cloud Run service for Phase 13 Computer Use audit proof validation.

Firebase Functions run on Node.js and should not assume the official Python
OpenTimestamps client is installed in the runtime image. This service packages
`opentimestamps-client==0.7.2` and exposes one endpoint:

```http
POST /verify
content-type: application/json

{
  "proofBase64": "<chain.jsonl.ots bytes>",
  "chainFileBase64": "<optional chain.jsonl bytes>"
}
```

Response:

```json
{ "verified": true, "output": "ots verify output" }
```

Deploy:

```bash
PROJECT_ID=burnbar ./scripts/deploy-opentimestamps-verifier.sh
```

The deploy script keeps Cloud Run private by default, prints the two Firebase
Functions runtime variables required by `validateOpenTimestampsProof`, and
updates `functions/.env.<PROJECT_ID>` by default:

```bash
OPENBURNBAR_OTS_VERIFY_URL=https://<cloud-run-url>/verify
OPENBURNBAR_OTS_VERIFY_AUDIENCE=https://<cloud-run-url>
```

Set `WRITE_FUNCTIONS_ENV=false` to print the values without touching the local
Functions env file, or set `FUNCTIONS_ENV_FILE=functions/.env.<alias>` when the
Firebase deploy target uses a project alias.

When `OPENBURNBAR_OTS_VERIFY_AUDIENCE` is set, the Function fetches a Google
identity token from the metadata server and sends it as `Authorization: Bearer
...`, so the verifier does not need to be public. If the verifier URL is not
configured, `validateOpenTimestampsProof` falls back to a local
`OPENBURNBAR_OTS_VERIFY_BIN` / `ots` binary.

Local container smoke:

```bash
./scripts/test-opentimestamps-verifier-service.sh
```

The service exposes `GET /health` for local and production smoke checks. It
also accepts `GET /healthz` for compatibility with older local smoke scripts,
but production runbooks should use `/health`.

Bitcoin-header validation still depends on the proof being upgraded/anchored.
A fresh `.ots` proof can legitimately return a pending/not-yet-confirmed
message until a calendar attestation reaches Bitcoin.
