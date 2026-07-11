# Linux Attestation Facade

This service is the narrow trust boundary between OpenBurnBar's Linux client, Firebase, Keylime, and Cloud KMS. It has two independently deployable Cloud Run entrypoints built from one package.

## Trust boundaries

### Public ingress (`Dockerfile` target `ingress`)

The ingress accepts Firebase ID tokens, proxies enrollment to the private Keylime registrar over mTLS, and accepts bounded evidence objects. Enrollment derives the Keylime UUID from UID plus the AK-bound device ID, validates the DER EK certificate, stores its SPKI PEM and immutable TPM2B AK/EK identity, and fences registration attempts before the registrar call. Evidence uploads are digest-bound, generation-pinned, single-use, private, and short lived. The ingress has no KMS dependency in its module graph and must not receive the KMS signing IAM role.

### Private verifier (`Dockerfile` target `verifier`)

The verifier accepts only Google-signed Cloud Run ID tokens whose `aud` exactly matches `VERIFIER_OIDC_AUDIENCE` and whose verified service-account email exactly matches `VERIFIER_CALLER_SERVICE_ACCOUNT`. It resolves an active server-owned policy, requires an active UID/device/Keylime-agent enrollment, asks Keylime 7.14 API v2.5 to appraise TPM quote, IMA, and measured-boot evidence, and signs an allow verdict through an Ed25519 Cloud KMS key version. It does not implement TPM or IMA appraisal.

Both processes reject unknown JSON fields, cap request and dependency response sizes, disable redirects by using fixed mTLS request paths, never log request bodies, and return stable public errors rather than Keylime failure text. The verifier's Keylime response limit is derived from the configured evidence bound because Keylime 7.14.3 echoes the complete submitted IMA and measured-boot claims on success; the registrar uses a separate 2 MiB cap.

## Evidence lifecycle

1. The authenticated client creates an upload with its challenge bindings, exact byte count, and SHA-256 digest.
2. The client uploads one binary `OBBATST1` descriptor containing the complete IMA log, UEFI log, signed installed manifest, and detached manifest signature. GCS creation uses `ifGenerationMatch=0`; Firestore transitions `pending -> uploaded` once.
3. The Functions caller passes strict broker quote evidence, broker bundle metadata, and the returned `{uploadId,generation,sha256,size}` receipt to the private verifier with the original challenge.
4. A Firestore transaction leases the receipt to one verification fingerprint and an opaque fenced lease token. The verifier reads the exact GCS generation, validates the canonical four-record bundle and the packager-canonical signed release manifest (including its single trailing newline), and checks every quote/bundle/upload/challenge binding before Keylime.
5. Success stores and returns one signed envelope. An identical retry returns the cached envelope; a different request or terminal rejection cannot reuse the upload. Dependency outages release the short lease for a same-request retry.

## Keylime 7.14.3 contract

The v2.5 adapter is pinned to the one-shot interface in Keylime 7.14.3 source. It sends exactly `{type:"tpm",data:{nonce,quote,hash_alg,tpm_ak,tpm_ek,tpm_policy,runtime_policy,mb_policy,ima_measurement_list,mb_log}}`. The compound quote is `r<attestation>:<signature>:<pcr-values>`, the nonce is standard base64 for the recomputed 32-byte TPM extraData digest, AK is TPM2B base64, EK is certificate-derived SPKI PEM, policies are JSON strings, IMA is strict UTF-8 text without NUL bytes, and measured boot is standard base64. A success is accepted only when `{code:200,status:"Success",results:{valid:true,failures:[],claims}}` echoes the exact submitted data. Tests mirror the pinned source; deployment still requires live fixture certification against the deployed image.

Configure a GCS lifecycle rule that deletes objects shortly after their `customTime`. The application-level TTL is an authorization boundary; the bucket lifecycle rule is the storage cleanup backstop.

## Required configuration

Common: `GOOGLE_CLOUD_PROJECT`, `KEYLIME_MTLS_CA_FILE`, `KEYLIME_MTLS_CERT_FILE`, `KEYLIME_MTLS_KEY_FILE`, optional `KEYLIME_TIMEOUT_MILLIS` (45 seconds by default), and `PORT`.

Ingress: fixed private `KEYLIME_REGISTRAR_URL`, `EVIDENCE_BUCKET`, optional `EVIDENCE_MAX_BYTES`, optional `UPLOAD_TTL_MILLIS`, and optional `ENROLLMENT_LEASE_MILLIS` (75 seconds by default). The enrollment lease must exceed `KEYLIME_TIMEOUT_MILLIS`; startup fails closed when it does not.

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

Two cross-component gates are intentionally not invented here: the Functions caller must obtain and send the exact Cloud Run OIDC token required by the private verifier, and the public upload flow needs a server-issued challenge/upload ticket plus per-user quotas. Until those contracts and IAM bindings land, the public ingress must not be promoted as an abuse-resistant production endpoint.
