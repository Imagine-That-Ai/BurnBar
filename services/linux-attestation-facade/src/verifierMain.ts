import { applicationDefault, initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { keylimeVerifierResponseHardLimit, verifierConfig } from "./config.js";
import { FirestoreEnrollmentStore, FirestorePolicyStore, FirestoreUploadStateStore, GcsEvidenceObjectStore, GoogleOidcAuthenticator, readMtlsFiles } from "./googleAdapters.js";
import { KeylimeClient } from "./keylimeClient.js";
import { KmsEd25519Signer } from "./kmsSigner.js";
import { runServer } from "./runServer.js";
import { createVerifierServer } from "./verifierServer.js";
import { VerifierService } from "./verifierService.js";

async function main(): Promise<void> {
  const config = verifierConfig();
  const app = initializeApp({ credential: applicationDefault(), projectId: config.projectId });
  const firestore = getFirestore(app);
  const keylime = new KeylimeClient({
    baseUrl: config.keylimeVerifierUrl,
    credentials: await readMtlsFiles(config.keylimeCaFile, config.keylimeCertificateFile, config.keylimeKeyFile),
    timeoutMillis: config.keylimeTimeoutMillis,
    maxResponseBytes: keylimeVerifierResponseHardLimit(config.evidenceMaxBytes),
  });
  const service = new VerifierService(
    new FirestoreUploadStateStore(firestore),
    new GcsEvidenceObjectStore(config.evidenceBucket),
    new FirestoreEnrollmentStore(firestore),
    new FirestorePolicyStore(firestore),
    keylime,
    new KmsEd25519Signer(config.kmsKeyVersion),
    { nowMillis: Date.now },
    {
      issuer: config.verdictIssuer,
      audience: config.verdictAudience,
      maxEvidenceBytes: config.evidenceMaxBytes,
      verdictTtlMillis: config.verdictTtlMillis,
      verificationLeaseMillis: config.verificationLeaseMillis,
      maxClockSkewMillis: 5_000,
    },
  );
  await runServer(createVerifierServer(service, new GoogleOidcAuthenticator(config.oidcAudience, config.callerServiceAccount), 512 * 1024), config.port, "verifier");
}

main().catch(() => {
  console.error(JSON.stringify({ severity: "CRITICAL", event: "startup_failed", role: "verifier" }));
  process.exit(1);
});
