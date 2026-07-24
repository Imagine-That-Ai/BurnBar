import fs from 'node:fs';
import path from 'node:path';
import {
  INSTALLED_MANIFEST_PATH,
  INSTALLED_MANIFEST_SIGNATURE_PATH
} from './linux-installed-manifest.mjs';

const ATTESTATION_FILES = Object.freeze([
  { path: INSTALLED_MANIFEST_PATH, name: path.posix.basename(INSTALLED_MANIFEST_PATH) },
  { path: INSTALLED_MANIFEST_SIGNATURE_PATH, name: path.posix.basename(INSTALLED_MANIFEST_SIGNATURE_PATH) }
]);

/**
 * Replace the attestation files in an RPM staging tree with the manifest that
 * was signed for RPM. The RPM is rebuilt from a DEB payload, whose attestation
 * necessarily names packageFormat=deb, so leaving those bytes in place would
 * make the final RPM unverifiable even though its payload is otherwise exact.
 */
export function replaceRpmAttestationFromPayload({ extractedRoot, payloadAttestation }) {
  const root = path.resolve(extractedRoot);
  const sourceRoot = path.resolve(payloadAttestation);
  const rootStat = fs.lstatSync(root, { throwIfNoEntry: false });
  const sourceRootStat = fs.lstatSync(sourceRoot, { throwIfNoEntry: false });
  if (!rootStat?.isDirectory() || rootStat.isSymbolicLink()) {
    throw new Error('RPM extracted payload root is not a regular directory');
  }
  if (!sourceRootStat?.isDirectory() || sourceRootStat.isSymbolicLink()) {
    throw new Error('RPM payload attestation root is not a regular directory');
  }

  for (const entry of ATTESTATION_FILES) {
    const source = path.join(sourceRoot, entry.name);
    const sourceStat = fs.lstatSync(source, { throwIfNoEntry: false });
    if (!sourceStat?.isFile() || sourceStat.isSymbolicLink()) {
      throw new Error(`RPM payload attestation source is not a regular file: ${entry.name}`);
    }
    const relative = entry.path.slice(1).split('/');
    let ancestor = root;
    for (const component of relative.slice(0, -1)) {
      ancestor = path.join(ancestor, component);
      const ancestorStat = fs.lstatSync(ancestor, { throwIfNoEntry: false });
      if (!ancestorStat?.isDirectory() || ancestorStat.isSymbolicLink()) {
        throw new Error(`RPM extracted payload attestation path is not a trusted directory: ${entry.path}`);
      }
    }
    const destination = path.join(root, ...relative);
    const destinationStat = fs.lstatSync(destination, { throwIfNoEntry: false });
    if (!destinationStat?.isFile() || destinationStat.isSymbolicLink()) {
      throw new Error(`RPM extracted payload attestation destination is not a regular file: ${entry.path}`);
    }
    fs.copyFileSync(source, destination);
    fs.chmodSync(destination, 0o644);
  }
}
