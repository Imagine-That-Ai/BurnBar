import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  P39_AGGREGATE_PATH,
  P39_PLATFORM_INPUT_FILENAMES,
  resolveP39PlatformEvidence
} from './resolve-p39-platform-evidence.mjs';

const HEAD = 'a'.repeat(40);
const VERSION = '1.2.3';
const RUN_ID = '12345';
const DIGEST = `sha256:${'e'.repeat(64)}`;

function artifact(payload = {}) {
  return {
    schemaVersion: 1,
    id: 'openburnbar-platform-evidence-v1',
    targetHead: HEAD,
    version: VERSION,
    candidate: { runId: RUN_ID, artifactDigest: DIGEST },
    payload: {
      contract: 'openburnbar-g2-parser-output-v1',
      corpus: {
        source: 'OpenBurnBarCore/Sources/OpenBurnBarG2ParserParity/Fixtures/ParserContract/parser-output-golden.json',
        baselineSha256: 'a'.repeat(64)
      },
      observed: {
        source: 'OpenBurnBarG2ParserParity',
        invocation: 'swift run --package-path OpenBurnBarCore --disable-automatic-resolution OpenBurnBarG2ParserParity --write-golden',
        generatedSha256: 'b'.repeat(64),
        normalizedSha256: 'c'.repeat(64)
      },
      parserOutput: {
        formatVersion: 1,
        providers: ['test'],
        fixtures: [{
          fixtureId: 'fixture-1',
          parser: 'TestParser',
          provider: 'test',
          usageCount: 0,
          conversationCount: 0,
          usages: []
        }]
      },
      ...payload
    }
  };
}

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p39-resolve-'));
  const inputRoot = path.join(root, 'docs/linux-port/evidence/product-parity-inputs/P-39/ubuntu-24.04-gnome-x11-x86_64');
  fs.mkdirSync(path.join(inputRoot, '.linux-release'), { recursive: true });
  fs.writeFileSync(
    path.join(inputRoot, P39_AGGREGATE_PATH),
    `${JSON.stringify({ schemaVersion: 2, stage: 'candidate', targetHead: HEAD, version: VERSION })}\n`
  );
  for (const filename of Object.values(P39_PLATFORM_INPUT_FILENAMES)) {
    fs.writeFileSync(path.join(inputRoot, filename), `${JSON.stringify(artifact())}\n`);
  }
  return { root, inputRoot };
}

test('resolver finds and validates the exact candidate-bound platform pair', () => {
  const subject = fixture();
  try {
    const result = resolveP39PlatformEvidence({
      repoRoot: subject.root,
      inputRoot: subject.inputRoot,
      targetHead: HEAD,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST
    });
    assert.equal(result.version, VERSION);
    assert.equal(path.basename(result.macos), P39_PLATFORM_INPUT_FILENAMES.macos);
    assert.equal(path.basename(result.linux), P39_PLATFORM_INPUT_FILENAMES.linux);
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('resolver fails explicitly when the platform evidence producer is absent', () => {
  const subject = fixture();
  try {
    fs.rmSync(path.join(subject.inputRoot, P39_PLATFORM_INPUT_FILENAMES.macos));
    assert.throws(
      () => resolveP39PlatformEvidence({
        repoRoot: subject.root,
        inputRoot: subject.inputRoot,
        targetHead: HEAD,
        candidateRunId: RUN_ID,
        candidateArtifactDigest: DIGEST
      }),
      /platform evidence producer is absent.*macos-platform-evidence\.json/u
    );
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('resolver rejects stale candidate binding and duplicate source names', () => {
  const subject = fixture();
  try {
    const macos = path.join(subject.inputRoot, P39_PLATFORM_INPUT_FILENAMES.macos);
    const stale = artifact();
    stale.candidate.runId = '98765';
    fs.writeFileSync(macos, `${JSON.stringify(stale)}\n`);
    assert.throws(
      () => resolveP39PlatformEvidence({
        repoRoot: subject.root,
        inputRoot: subject.inputRoot,
        targetHead: HEAD,
        candidateRunId: RUN_ID,
        candidateArtifactDigest: DIGEST
      }),
      /candidate run id/u
    );

    fs.writeFileSync(macos, `${JSON.stringify(artifact())}\n`);
    const duplicateDir = path.join(subject.inputRoot, 'nested');
    fs.mkdirSync(duplicateDir);
    fs.writeFileSync(path.join(duplicateDir, P39_PLATFORM_INPUT_FILENAMES.macos), `${JSON.stringify(artifact())}\n`);
    assert.throws(
      () => resolveP39PlatformEvidence({
        repoRoot: subject.root,
        inputRoot: subject.inputRoot,
        targetHead: HEAD,
        candidateRunId: RUN_ID,
        candidateArtifactDigest: DIGEST
      }),
      /requires exactly one macos-platform-evidence\.json/u
    );
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('resolver rejects an aggregate closure for a different commit', () => {
  const subject = fixture();
  try {
    const aggregate = path.join(subject.inputRoot, P39_AGGREGATE_PATH);
    fs.writeFileSync(aggregate, `${JSON.stringify({ schemaVersion: 2, stage: 'candidate', targetHead: 'b'.repeat(40), version: VERSION })}\n`);
    assert.throws(
      () => resolveP39PlatformEvidence({
        repoRoot: subject.root,
        inputRoot: subject.inputRoot,
        targetHead: HEAD,
        candidateRunId: RUN_ID,
        candidateArtifactDigest: DIGEST
      }),
      /target does not match/u
    );
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('resolver rejects candidate-bound synthetic payloads', () => {
  const subject = fixture();
  try {
    const macos = path.join(subject.inputRoot, P39_PLATFORM_INPUT_FILENAMES.macos);
    const synthetic = artifact({ generatedAt: '2026-01-01T00:00:00.000Z' });
    fs.writeFileSync(macos, `${JSON.stringify(synthetic)}\n`);
    assert.throws(
      () => resolveP39PlatformEvidence({
        repoRoot: subject.root,
        inputRoot: subject.inputRoot,
        targetHead: HEAD,
        candidateRunId: RUN_ID,
        candidateArtifactDigest: DIGEST
      }),
      /P-39 producer payload fields must be exactly/u
    );
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});
