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

Deploy sketch:

```bash
gcloud run deploy openburnbar-ots-verifier \
  --source tools/opentimestamps-verifier-service \
  --region us-central1 \
  --no-allow-unauthenticated

firebase functions:config:set \
  openburnbar.ots_verify_url="https://<cloud-run-url>/verify"
```

Then set `OPENBURNBAR_OTS_VERIFY_URL` in the Functions runtime environment.
`validateOpenTimestampsProof` will call this service before falling back to a
local `OPENBURNBAR_OTS_VERIFY_BIN` / `ots` binary.

Bitcoin-header validation still depends on the proof being upgraded/anchored.
A fresh `.ots` proof can legitimately return a pending/not-yet-confirmed
message until a calendar attestation reaches Bitcoin.
