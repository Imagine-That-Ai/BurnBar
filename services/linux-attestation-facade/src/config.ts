import { integer, string } from "./validation.js";
import { MAX_EVIDENCE_BYTES } from "./constants.js";

function required(name: string): string {
  return string(process.env[name], name, 2048);
}

function positive(name: string, fallback: number, max: number): number {
  const raw = process.env[name];
  return raw === undefined ? fallback : integer(Number(raw), name, 1, max);
}

function fixedHttpsOrigin(name: string): URL {
  const url = new URL(required(name));
  if (url.protocol !== "https:" || url.username !== "" || url.password !== "" || url.search !== "" || url.hash !== "") throw new Error(`${name} must be a fixed HTTPS URL`);
  return url;
}

export function keylimeVerifierResponseHardLimit(evidenceMaxBytes: number): number {
  if (!Number.isSafeInteger(evidenceMaxBytes) || evidenceMaxBytes <= 0 || evidenceMaxBytes > MAX_EVIDENCE_BYTES) {
    throw new Error("EVIDENCE_MAX_BYTES is invalid");
  }
  return evidenceMaxBytes * 2 + 8 * 1024 * 1024;
}

export function commonConfig() {
  return {
    port: positive("PORT", 8080, 65535),
    projectId: required("GOOGLE_CLOUD_PROJECT"),
    keylimeCaFile: required("KEYLIME_MTLS_CA_FILE"),
    keylimeCertificateFile: required("KEYLIME_MTLS_CERT_FILE"),
    keylimeKeyFile: required("KEYLIME_MTLS_KEY_FILE"),
    keylimeTimeoutMillis: positive("KEYLIME_TIMEOUT_MILLIS", 45_000, 60_000),
  };
}

export function ingressConfig() {
  const common = commonConfig();
  const enrollmentLeaseMillis = positive("ENROLLMENT_LEASE_MILLIS", 75_000, 110_000);
  const activationLeaseMillis = positive(
    "ACTIVATION_LEASE_MILLIS",
    common.keylimeTimeoutMillis * 2 + 15_000,
    150_000,
  );
  if (enrollmentLeaseMillis <= common.keylimeTimeoutMillis) {
    throw new Error("ENROLLMENT_LEASE_MILLIS must exceed KEYLIME_TIMEOUT_MILLIS");
  }
  if (activationLeaseMillis <= common.keylimeTimeoutMillis * 2) {
    throw new Error("ACTIVATION_LEASE_MILLIS must exceed twice KEYLIME_TIMEOUT_MILLIS");
  }
  return {
    ...common,
    keylimeRegistrarUrl: fixedHttpsOrigin("KEYLIME_REGISTRAR_URL"),
    evidenceBucket: required("EVIDENCE_BUCKET"),
    evidenceMaxBytes: positive("EVIDENCE_MAX_BYTES", 16 * 1024 * 1024, 16 * 1024 * 1024),
    uploadMaxAttempts: positive("UPLOAD_MAX_ATTEMPTS", 3, 3),
    enrollmentLeaseMillis,
    activationLeaseMillis,
    enrollmentMaxAttempts: positive("ENROLLMENT_MAX_ATTEMPTS", 3, 3),
  };
}

export function verifierConfig() {
  return {
    ...commonConfig(),
    keylimeVerifierUrl: fixedHttpsOrigin("KEYLIME_VERIFIER_URL"),
    evidenceBucket: required("EVIDENCE_BUCKET"),
    evidenceMaxBytes: positive("EVIDENCE_MAX_BYTES", MAX_EVIDENCE_BYTES, MAX_EVIDENCE_BYTES),
    oidcAudience: required("VERIFIER_OIDC_AUDIENCE"),
    callerServiceAccount: required("VERIFIER_CALLER_SERVICE_ACCOUNT"),
    kmsKeyVersion: required("KMS_SIGNING_KEY_VERSION"),
    verdictIssuer: required("VERDICT_ISSUER"),
    verdictAudience: required("VERDICT_AUDIENCE"),
    verdictTtlMillis: positive("VERDICT_TTL_MILLIS", 60_000, 2 * 60 * 1000),
    verificationLeaseMillis: positive("VERIFICATION_LEASE_MILLIS", 75_000, 110_000),
  };
}
