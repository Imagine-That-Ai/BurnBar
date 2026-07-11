# Linux Attestation Facade

This service is the narrow trust boundary between OpenBurnBar's Linux client, Firebase, Keylime, and Cloud KMS. It has two independently deployable Cloud Run entrypoints built from one package.

## Trust boundaries

### Public ingress (`Dockerfile` target `ingress`)

The ingress accepts revoked-checked Firebase ID tokens plus separate purpose-bound bootstrap tickets, proxies enrollment to the private Keylime registrar over mTLS, and accepts bounded evidence objects. Functions stores only a domain-separated ticket-secret hash; the raw 32-byte secret appears only in the client-built `X-OpenBurnBar-Attestation-Ticket` header. Enrollment derives the Keylime UUID from UID plus the AK-bound device ID, validates the DER EK certificate, stores its SPKI PEM and immutable TPM2B AK/EK identity, and fences at most three registrar attempts under one enrollment ticket. Activation uses a separate fenced Firestore lease and reconciles Keylime's exact AK, EK, certificate, and agent ID before local commit, including after ambiguous remote or Firestore responses. Evidence upload claim and server-owned upload-record creation are one Firestore transaction; uploads are digest-bound, generation-pinned, private, and cannot outlive the challenge ticket. Every PUT is charged before its body is read and a reservation accepts at most three total body attempts, including receipt retries. The ingress has no KMS dependency in its module graph and must not receive the KMS signing IAM role.

### Private verifier (`Dockerfile` target `verifier`)

The verifier accepts only Google-signed Cloud Run ID tokens whose `aud` exactly matches `VERIFIER_OIDC_AUDIENCE` and whose verified service-account email exactly matches `VERIFIER_CALLER_SERVICE_ACCOUNT`. It resolves an active server-owned policy, requires an active UID/device/Keylime-agent enrollment, asks Keylime 7.14 API v2.5 to appraise TPM quote, IMA, and measured-boot evidence, and signs an allow verdict through an Ed25519 Cloud KMS key version. It does not implement TPM or IMA appraisal.

Both processes reject unknown JSON fields, cap request and dependency response sizes, disable redirects by using fixed mTLS request paths, never log request bodies, and return stable public errors rather than Keylime failure text. The verifier's Keylime response limit is derived from the configured evidence bound because Keylime 7.14.3 echoes the complete submitted IMA and measured-boot claims on success; the registrar uses a separate 2 MiB cap.

## Evidence lifecycle

1. Functions issues a UID/device-bound challenge. The broker produces the quote and one binary `OBBATST1` descriptor containing the complete IMA log, UEFI log, signed installed manifest, and detached manifest signature.
2. The client asks Functions for an upload ticket bound to the still-unconsumed challenge, exact descriptor byte count and SHA-256 digest. The client supplies only a domain-separated hash of its random ticket secret; Functions atomically reserves count/byte quota and stores no raw secret.
3. The authenticated client claims that ticket through `X-OpenBurnBar-Attestation-Ticket`. Ingress atomically creates one server-selected upload ID/object path and returns the same result after response loss. Before reading each descriptor body, ingress transactionally charges one of three attempts and loads the exact expected size; malformed, abandoned, and successful retry bodies all count. GCS creation uses `ifGenerationMatch=0` and Firestore transitions `pending -> uploaded` once.
4. The Functions caller passes strict broker quote evidence, broker bundle metadata, and the returned `{uploadId,generation,sha256,size}` receipt to the private verifier with the original challenge.
5. A Firestore transaction leases the receipt to one verification fingerprint and an opaque fenced lease token. The verifier reads the exact GCS generation, validates the canonical four-record bundle and the packager-canonical signed release manifest (including its single trailing newline), and checks every quote/bundle/upload/challenge binding before Keylime.
6. Success stores and returns one signed envelope. An identical retry returns the cached envelope; a different request or terminal rejection cannot reuse the upload. Dependency outages release the short lease for a same-request retry.

## Keylime 7.14.3 contract

The v2.5 adapter is pinned to the one-shot interface in Keylime 7.14.3 source. It sends exactly `{type:"tpm",data:{nonce,quote,hash_alg,tpm_ak,tpm_ek,tpm_policy,runtime_policy,mb_policy,ima_measurement_list,mb_log}}`. The compound quote is `r<attestation>:<signature>:<pcr-values>`, the nonce is standard base64 for the recomputed 32-byte TPM extraData digest, AK is TPM2B base64, EK is certificate-derived SPKI PEM, policies are JSON strings, IMA is strict UTF-8 text without NUL bytes, and measured boot is standard base64. A success is accepted only when `{code:200,status:"Success",results:{valid:true,failures:[],claims}}` echoes the exact submitted data. Tests mirror the pinned source; deployment still requires live fixture certification against the deployed image.

Configure a GCS lifecycle rule that deletes objects shortly after their `customTime`. The application-level TTL is an authorization boundary; the bucket lifecycle rule is the storage cleanup backstop.

## Required configuration

Common: `GOOGLE_CLOUD_PROJECT`, `KEYLIME_MTLS_CA_FILE`, `KEYLIME_MTLS_CERT_FILE`, `KEYLIME_MTLS_KEY_FILE`, optional `KEYLIME_TIMEOUT_MILLIS` (45 seconds by default), and `PORT`.

Ingress: fixed private `KEYLIME_REGISTRAR_URL`, `EVIDENCE_BUCKET`, optional `EVIDENCE_MAX_BYTES` (16 MiB and never configurable above 16 MiB), optional `UPLOAD_MAX_ATTEMPTS` (three and never configurable above three), optional `ENROLLMENT_LEASE_MILLIS` (75 seconds by default), optional `ACTIVATION_LEASE_MILLIS` (two Keylime request timeouts plus 15 seconds by default), and optional `ENROLLMENT_MAX_ATTEMPTS` (three and never configurable above three). The registration lease must exceed one `KEYLIME_TIMEOUT_MILLIS`; the activation lease is renewed immediately before PUT and must exceed two timeouts so the mutation and reconciliation GET remain fenced. Ambiguous mutation failures retain that lease until expiry. Startup fails closed when either timing invariant is violated. Upload expiry is server-owned ticket state, and `linux_attestation_uploads.expireAt` is registered for Firestore TTL cleanup after the five-minute window. Larger evidence requires a future digest-bound direct GCS upload path; it must not be proxied through Cloud Run's HTTP/1 request body.

Verifier: fixed private `KEYLIME_VERIFIER_URL`, `EVIDENCE_BUCKET`, `VERIFIER_OIDC_AUDIENCE`, `VERIFIER_CALLER_SERVICE_ACCOUNT`, `KMS_SIGNING_KEY_VERSION`, `VERDICT_ISSUER`, `VERDICT_AUDIENCE`, optional `EVIDENCE_MAX_BYTES`, optional `VERDICT_TTL_MILLIS`, and optional `VERIFICATION_LEASE_MILLIS` (75 seconds by default and longer than the Functions request budget).

Mount mTLS material from Secret Manager as read-only files. Grant ingress only Firebase token verification, service-owned Firestore collections, evidence-object creation, and Keylime registrar network access. Grant verifier evidence-object read, service-owned Firestore collections, Keylime verifier network access, and `cloudkms.cryptoKeyVersions.useToSign` on one key version. Do not give either service broad project roles.

## Development

```bash
npm ci
npm run lint
npm run typecheck
npm test
npm run build
docker build --target ingress -t openburnbar-linux-attestation-ingress .
docker build --target verifier -t openburnbar-linux-attestation-verifier .
```

## Deployment blockers

This package is a deployable foundation, not proof that the private attestation plane exists. Production remains blocked until the private Keylime registrar/verifier deployment, GKE/private networking, managed PostgreSQL, mTLS CA and certificate rotation, KMS key/public-key publication, GCS lifecycle policy, Firestore security/IAM policy, Cloud Run service identities, dependency-aware readiness/metrics, and end-to-end TPM hardware validation are deployed and independently verified. The deployed Keylime 7.14.3 image must pass live request/response fixtures before promotion.

Public ingress promotion still requires deployed and independently exercised Functions ticket issuance, per-user count/byte quotas, exact Firestore ticket TTL/IAM policy, Cloud Armor/per-IP shielding, and the Functions-to-verifier Cloud Run OIDC binding. Source-level ticket enforcement is necessary but is not deployment proof.
