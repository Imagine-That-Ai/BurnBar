import assert from 'node:assert/strict';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import {
  P40_DEFAULT_RETENTION_RULES,
  P40_ENVIRONMENTS,
  P40_RETENTION_CONTRACT,
  P40_RPC_METHODS,
  P40_STORES
} from './lib/p40-privacy-proof.mjs';
import { buildSession, parseArguments } from './run-p40-privacy-rpc-session.mjs';

const PRODUCER_SOURCE = fs.readFileSync(
  fileURLToPath(new URL('./run-p40-privacy-rpc-session.mjs', import.meta.url)),
  'utf8'
);

const ENVIRONMENT = 'ubuntu-24.04-gnome-x11-aarch64';
const HEAD = 'a'.repeat(40);
const RUN_ID = '29351903622';
const DIGEST = `sha256:${'b'.repeat(64)}`;
const OPTIONS = {
  environmentId: ENVIRONMENT,
  targetHead: HEAD,
  candidateRunId: RUN_ID,
  candidateArtifactDigest: DIGEST,
  packageVersion: '1.2.3',
  manifestSha256: 'c'.repeat(64)
};

function observations() {
  return {
    inventory: {
      evidencePaths: ['privacy/inventory.json'],
      metadataOnly: true,
      noAbsolutePaths: true,
      noContents: true,
      stores: P40_STORES.map((store) => ({ store, state: 'ready', bytes: 128 }))
    },
    deletion: {
      changedPreviewRejected: true,
      confirmationExact: true,
      evidencePaths: ['privacy/deletion.json'],
      expiredPreviewRejected: true,
      idempotent: true,
      noAbsolutePaths: true,
      noContentsReturned: true,
      outsidePathUntouched: true,
      previewScopeBound: true,
      selectedScope: true
    },
    export: {
      encrypted: true,
      evidencePaths: ['privacy/export.json'],
      formatVersion: 1,
      noPlaintextOnDisk: true,
      ownerOnlyPermissions: true,
      passphraseNotPersisted: true,
      selectedScope: true
    },
    retention: {
      agedExpansionPurged: true,
      appliedRules: P40_STORES.map((store) => ({ store, maxAgeSeconds: 3_600, maxBytes: 65_536 })),
      defaultRules: structuredClone(P40_DEFAULT_RETENTION_RULES),
      evidencePaths: ['privacy/retention.json'],
      freshRouteRetained: true,
      invalidBoundsRejected: true,
      invalidConfirmationRejected: true,
      malformedStoreFailClosed: true,
      noMutationOnFailure: true,
      oldRoutePurged: true,
      statusObserved: true
    }
  };
}

test('argument parser requires candidate identity and absolute runtime paths', () => {
  const args = [
    '--socket', '/run/user/1000/openburnbar/daemon.sock',
    '--token-file', '/home/burnbar/.cache/openburnbar-p40-1/support/daemon-socket-auth-token',
    '--output-root', '/home/burnbar/.cache/openburnbar-p40-1/evidence',
    '--environment', ENVIRONMENT,
    '--target-head', HEAD,
    '--candidate-run-id', RUN_ID,
    '--candidate-artifact-digest', DIGEST,
    '--package-version', '1.2.3',
    '--manifest-sha256', 'c'.repeat(64)
  ];
  const parsed = parseArguments(args);
  assert.equal(parsed.environmentId, ENVIRONMENT);
  assert.throws(() => parseArguments(args.slice(0, -2)), /--manifest-sha256 is required/u);
  assert.throws(() => parseArguments(args.map((value) => value === '/run/user/1000/openburnbar/daemon.sock' ? 'relative.sock' : value)), /socket must be absolute/u);
  assert.throws(() => parseArguments([...args, '--unknown', 'value']), /invalid argument/u);
});

test('live producer uses the installed authorized CLI peer', () => {
  assert.match(PRODUCER_SOURCE, /const CLI_BINARY_PATH = '\/usr\/bin\/openburnbar-cli';/u);
  assert.match(PRODUCER_SOURCE, /spawnSync\(CLI_BINARY_PATH, \['privacy-rpc'\]/u);
  assert.match(PRODUCER_SOURCE, /OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE/u);
  assert.doesNotMatch(PRODUCER_SOURCE, /net\.createConnection/u);
  assert.doesNotMatch(PRODUCER_SOURCE, /daemon\.health/u);
  assert.match(PRODUCER_SOURCE, /activeGnomeShellEnvironment/u);
  assert.match(PRODUCER_SOURCE, /XDG_CURRENT_DESKTOP/u);
});

test('session builder emits exactly the redacted live P-40 schema', () => {
  const session = buildSession(
    OPTIONS,
    P40_ENVIRONMENTS[ENVIRONMENT],
    OPTIONS.packageVersion,
    OPTIONS.manifestSha256,
    observations()
  );
  assert.equal(session.capture.mode, 'installed-rpc');
  assert.deepEqual(session.daemon.rpcMethods, [...P40_RPC_METHODS]);
  assert.deepEqual(session.contract.defaultRetentionRules, [...P40_DEFAULT_RETENTION_RULES]);
  assert.equal(session.contract.confirmationPhrase, P40_RETENTION_CONTRACT.confirmationPhrase);
  assert.equal(session.package.source, 'signed-installed-candidate');
  assert.equal(session.daemon.source, 'installed-candidate-daemon');
  assert.doesNotMatch(JSON.stringify(session), /"(?:token|passphrase|absolutePath|contents|destinationPath|storePath|rawBytes)"/iu);
  assert.throws(() => buildSession(
    { ...OPTIONS, candidateArtifactDigest: 'not-a-digest' },
    P40_ENVIRONMENTS[ENVIRONMENT],
    OPTIONS.packageVersion,
    OPTIONS.manifestSha256,
    observations()
  ), /candidate artifact digest/u);
});
