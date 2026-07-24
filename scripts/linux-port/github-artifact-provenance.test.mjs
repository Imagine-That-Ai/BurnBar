import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  buildGitHubArtifactVerificationArgs,
  verifyGitHubArtifactProvenance
} from './lib/github-artifact-provenance.mjs';

const REPOSITORY = 'example/openburnbar';
const WORKFLOW = 'example/openburnbar/.github/workflows/linux-product-evidence.yml';
const HEAD = 'a'.repeat(40);
const SOURCE_REF = 'refs/heads/main';

function setup(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'github-artifact-provenance-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const receiptPath = path.join(root, 'receipt.json');
  const bundlePath = path.join(root, 'receipt.bundle.json');
  fs.writeFileSync(receiptPath, '{"status":"passed"}\n');
  fs.writeFileSync(bundlePath, '{}\n');
  return {
    receiptPath,
    bundlePath,
    repository: REPOSITORY,
    signerWorkflow: WORKFLOW,
    sourceDigest: HEAD,
    sourceRef: SOURCE_REF
  };
}

function receiptDigest(options) {
  return crypto.createHash('sha256').update(fs.readFileSync(options.receiptPath)).digest('hex');
}

function validOutput(options, overrides = {}) {
  const workflowUrl = `https://github.com/${WORKFLOW}@refs/heads/main`;
  const certificate = {
    subjectAlternativeName: workflowUrl,
    buildSignerURI: workflowUrl,
    sourceRepositoryURI: `https://github.com/${REPOSITORY}`,
    sourceRepositoryDigest: HEAD,
    sourceRepositoryRef: SOURCE_REF,
    ...overrides.certificate
  };
  const subject = [{ name: 'receipt.json', digest: { sha256: receiptDigest(options) } }];
  return JSON.stringify([{
    attestation: { bundle: 'opaque' },
    verificationResult: {
      statement: {
        subject: overrides.subject ?? subject,
        predicate: { untrusted: true, repository: 'attacker-controlled' }
      },
      signature: { certificate }
    }
  }]);
}

function successSpawn(stdout, calls) {
  return (command, args, options) => {
    calls.push({ command, args, options });
    return { status: 0, signal: null, stdout, stderr: '' };
  };
}

test('invokes gh with the complete exact provenance policy and validates its result', (t) => {
  const options = setup(t);
  const calls = [];
  const result = verifyGitHubArtifactProvenance(options, {
    spawnSync: successSpawn(validOutput(options), calls)
  });

  assert.equal(result.receiptSha256, receiptDigest(options));
  assert.equal(result.verifiedAttestationCount, 1);
  assert.deepEqual(calls, [{
    command: 'gh',
    args: [
      'attestation', 'verify', options.receiptPath,
      '--repo', REPOSITORY,
      '--bundle', options.bundlePath,
      '--signer-workflow', WORKFLOW,
      '--source-digest', HEAD,
      '--source-ref', SOURCE_REF,
      '--format', 'json'
    ],
    options: {
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024,
      windowsHide: true
    }
  }]);
});

test('rejects malformed policy inputs before executing gh', (t) => {
  const options = setup(t);
  const invalid = [
    { repository: 'example' },
    { signerWorkflow: `${WORKFLOW}@refs/heads/main` },
    { sourceDigest: 'a'.repeat(39) },
    { sourceDigest: 'not-a-commit' },
    { sourceRef: 'main' },
    { sourceRef: 'refs/heads/../main' }
  ];
  for (const mutation of invalid) {
    assert.throws(() => buildGitHubArtifactVerificationArgs({ ...options, ...mutation }));
  }
});

test('preserves an explicit github.com signer workflow identity in the gh policy', (t) => {
  const options = setup(t);
  const workflow = `github.com/${WORKFLOW}`;
  const args = buildGitHubArtifactVerificationArgs({ ...options, signerWorkflow: workflow });
  assert.equal(args[args.indexOf('--signer-workflow') + 1], workflow);
});

test('fails closed when the verified certificate names a different repository', (t) => {
  const options = setup(t);
  const stdout = validOutput(options, {
    certificate: { sourceRepositoryURI: 'https://github.com/attacker/fork' }
  });
  assert.throws(
    () => verifyGitHubArtifactProvenance(options, { spawnSync: successSpawn(stdout, []) }),
    /wrong source repository identity/u
  );
});

test('fails closed when the verified certificate names a different workflow', (t) => {
  const options = setup(t);
  const stdout = validOutput(options, {
    certificate: {
      subjectAlternativeName: 'https://github.com/example/openburnbar/.github/workflows/other.yml@refs/heads/main'
    }
  });
  assert.throws(
    () => verifyGitHubArtifactProvenance(options, { spawnSync: successSpawn(stdout, []) }),
    /wrong signer workflow identity/u
  );
});

test('fails closed when the verified certificate build signer disagrees with the workflow', (t) => {
  const options = setup(t);
  const stdout = validOutput(options, {
    certificate: {
      buildSignerURI: 'https://github.com/example/openburnbar/.github/workflows/other.yml@refs/heads/main'
    }
  });
  assert.throws(
    () => verifyGitHubArtifactProvenance(options, { spawnSync: successSpawn(stdout, []) }),
    /wrong build signer identity/u
  );
});

test('fails closed when the verified certificate names a different source ref', (t) => {
  const options = setup(t);
  const stdout = validOutput(options, {
    certificate: { sourceRepositoryRef: 'refs/heads/untrusted' }
  });
  assert.throws(
    () => verifyGitHubArtifactProvenance(options, { spawnSync: successSpawn(stdout, []) }),
    /wrong source repository ref/u
  );
});

test('fails closed when the verified certificate names a different source HEAD', (t) => {
  const options = setup(t);
  const stdout = validOutput(options, {
    certificate: { sourceRepositoryDigest: 'b'.repeat(40) }
  });
  assert.throws(
    () => verifyGitHubArtifactProvenance(options, { spawnSync: successSpawn(stdout, []) }),
    /wrong source repository digest/u
  );
});

test('fails closed when the statement does not bind the receipt digest', (t) => {
  const options = setup(t);
  const stdout = validOutput(options, {
    subject: [{ name: 'receipt.json', digest: { sha256: 'b'.repeat(64) } }]
  });
  assert.throws(
    () => verifyGitHubArtifactProvenance(options, { spawnSync: successSpawn(stdout, []) }),
    /does not bind the receipt SHA-256 digest/u
  );
});

test('fails closed when gh reports a bundle mismatch', (t) => {
  const options = setup(t);
  const spawn = () => ({
    status: 1,
    signal: null,
    stdout: '',
    stderr: 'bundle subject did not match artifact digest'
  });
  assert.throws(
    () => verifyGitHubArtifactProvenance(options, { spawnSync: spawn }),
    /bundle subject did not match artifact digest/u
  );
});

test('fails closed when gh is missing', (t) => {
  const options = setup(t);
  const error = Object.assign(new Error('spawnSync gh ENOENT'), { code: 'ENOENT' });
  assert.throws(
    () => verifyGitHubArtifactProvenance(options, { spawnSync: () => ({ error, status: null }) }),
    /not installed or not available on PATH/u
  );
});

test('fails closed on malformed, empty, or incomplete gh JSON output', (t) => {
  const options = setup(t);
  const outputs = [
    'not-json',
    '{}',
    '[]',
    '[{}]',
    '[{"verificationResult":{"statement":{"subject":[]}}}]'
  ];
  for (const stdout of outputs) {
    assert.throws(
      () => verifyGitHubArtifactProvenance(options, { spawnSync: successSpawn(stdout, []) })
    );
  }
});

test('does not trust statement predicate identity fields', (t) => {
  const options = setup(t);
  const stdout = validOutput(options);
  assert.doesNotThrow(
    () => verifyGitHubArtifactProvenance(options, { spawnSync: successSpawn(stdout, []) })
  );
});
