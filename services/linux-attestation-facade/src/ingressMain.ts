import { applicationDefault, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { ingressConfig } from "./config.js";
import { FirebaseUserAuthenticator, FirestoreEnrollmentStore, FirestoreUploadStateStore, GcsEvidenceObjectStore, readMtlsFiles } from "./googleAdapters.js";
import { createIngressServer } from "./ingressServer.js";
import { IngressService } from "./ingressService.js";
import { KeylimeClient } from "./keylimeClient.js";
import { runServer } from "./runServer.js";

async function main(): Promise<void> {
  const config = ingressConfig();
  const app = initializeApp({ credential: applicationDefault(), projectId: config.projectId });
  const firestore = getFirestore(app);
  const keylime = new KeylimeClient({
    baseUrl: config.keylimeRegistrarUrl,
    credentials: await readMtlsFiles(config.keylimeCaFile, config.keylimeCertificateFile, config.keylimeKeyFile),
    timeoutMillis: config.keylimeTimeoutMillis,
    maxResponseBytes: 2 * 1024 * 1024,
  });
  const service = new IngressService(
    new FirestoreUploadStateStore(firestore),
    new GcsEvidenceObjectStore(config.evidenceBucket),
    new FirestoreEnrollmentStore(firestore),
    keylime,
    {
      maxEvidenceBytes: config.evidenceMaxBytes,
      uploadTtlMillis: config.uploadTtlMillis,
      enrollmentLeaseMillis: config.enrollmentLeaseMillis,
    },
  );
  await runServer(createIngressServer(service, new FirebaseUserAuthenticator(getAuth(app)), {
    jsonBodyLimit: 512 * 1024,
    evidenceBodyLimit: config.evidenceMaxBytes,
  }), config.port, "ingress");
}

main().catch(() => {
  console.error(JSON.stringify({ severity: "CRITICAL", event: "startup_failed", role: "ingress" }));
  process.exit(1);
});
