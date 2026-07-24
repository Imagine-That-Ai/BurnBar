import crypto from 'node:crypto';
import { result, validateRequirementContext } from './lib.mjs';
import { RELEASE_ARCHITECTURES, RELEASE_ARTIFACT_TYPES } from '../lib/product-proof-closure.mjs';

const REQUIRED = [
  'aggregate-product-proof-closure', 'checksums', 'sbom', 'vex', 'provenance',
  'source-archive', 'update-feed', 'update-feed-signature',
  'update-feed-sigstore', 'release-public-key', 'release-artifact',
  'package-signature', 'package-sigstore'
];

const RELEASE_KEYS = RELEASE_ARTIFACT_TYPES.flatMap((format) =>
  RELEASE_ARCHITECTURES.map((architecture) => `${format}:${architecture}`)
);

function exactReleaseMatrix(rows, role) {
  const keys = rows.map((row) => `${row.format}:${row.architecture}`);
  if (rows.length !== RELEASE_KEYS.length || new Set(keys).size !== RELEASE_KEYS.length
      || RELEASE_KEYS.some((key) => !keys.includes(key))) {
    throw new Error(`${role} proof must cover every release binary and architecture exactly once`);
  }
  return new Map(rows.map((row) => [`${row.format}:${row.architecture}`, row]));
}

export async function validateProductRequirement(context) {
  const validated = validateRequirementContext(context, REQUIRED);
  const artifacts = exactReleaseMatrix(validated.proofs.get('release-artifact'), 'release-artifact');
  const signatures = exactReleaseMatrix(validated.proofs.get('package-signature'), 'package-signature');
  exactReleaseMatrix(validated.proofs.get('package-sigstore'), 'package-sigstore');
  const publicKeys = validated.proofs.get('release-public-key');
  if (publicKeys.length !== 1) throw new Error('release-public-key proof must occur exactly once');
  let publicKey;
  try {
    publicKey = crypto.createPublicKey(publicKeys[0].snapshot.bytes);
  } catch (error) {
    throw new Error(`release public key proof is invalid: ${error.message}`);
  }
  if (publicKey.asymmetricKeyType !== 'ed25519') throw new Error('release public key proof is not Ed25519');
  for (const key of RELEASE_KEYS) {
    const signature = signatures.get(key).snapshot.bytes;
    if (signature.length !== 64
        || !crypto.verify(null, artifacts.get(key).snapshot.bytes, publicKey, signature)) {
      throw new Error(`release artifact signature does not verify: ${key}`);
    }
  }
  const feeds = validated.proofs.get('update-feed');
  const feedSignatures = validated.proofs.get('update-feed-signature');
  if (feeds.length !== 1 || feedSignatures.length !== 1 || feedSignatures[0].snapshot.size !== 64
      || !crypto.verify(null, feeds[0].snapshot.bytes, publicKey, feedSignatures[0].snapshot.bytes)) {
    throw new Error('update feed signature does not verify with the release key');
  }
  return result(context, validated.artifacts);
}
