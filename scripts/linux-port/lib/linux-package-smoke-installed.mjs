import { verifyLiveInstalledProduct } from './live-installed-product-evidence.mjs';

export function installedPackageVerificationStep({
  artifact,
  readSubject,
  verifier = verifyLiveInstalledProduct
}) {
  const command = `verify live signed installed ${artifact.type} inventory ${artifact.architecture}`;
  try {
    const manifestBytes = readSubject(artifact.installedManifest, `${artifact.type} installed manifest`);
    const signatureBytes = readSubject(
      artifact.installedManifestSignature,
      `${artifact.type} installed manifest signature`
    );
    let installedManifest;
    try {
      installedManifest = JSON.parse(manifestBytes.toString('utf8'));
    } catch (error) {
      throw new Error(`${artifact.type} installed manifest is not valid JSON: ${error.message}`);
    }
    const result = verifier({
      installedManifest,
      expectedManifestBytes: manifestBytes,
      expectedSignatureBytes: signatureBytes
    });
    return { command, cwd: '.', exitCode: 0, stdout: JSON.stringify(result.verification), stderr: '' };
  } catch (error) {
    return { command, cwd: '.', exitCode: 1, stdout: '', stderr: error.message };
  }
}
