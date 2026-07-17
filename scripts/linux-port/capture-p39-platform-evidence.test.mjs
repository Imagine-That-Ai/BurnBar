import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  captureP39PlatformEvidence,
  runG2ParserParity,
  validateParserOutput
} from './capture-p39-platform-evidence.mjs';

const HEAD = 'a'.repeat(40);
const RUN_ID = '12345';
const DIGEST = `sha256:${'b'.repeat(64)}`;

function parserOutput(overrides = {}) {
  return {
    formatVersion: 1,
    providers: ['Claude Code'],
    fixtures: [{
      fixtureId: 'fixture-1',
      parser: 'ClaudeCodeParser',
      provider: 'Claude Code',
      usageCount: 1,
      conversationCount: 1,
      usages: [{
        provider: 'Claude Code',
        sessionId: 'session-1',
        projectName: '~/ParserContract',
        model: 'claude-sonnet-4-20250514',
        inputTokens: 10,
        outputTokens: 4,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        reasoningTokens: 0,
        totalTokens: 14,
        costNanoUSD: 120,
        usageSource: 'provider_log',
        provenanceMethod: 'provider_log',
        provenanceConfidence: 'exact',
        estimatorVersion: 'v1'
      }]
    }],
    ...overrides
  };
}

function fixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-p39-producer-'));
  const golden = path.join(root, 'OpenBurnBarCore/Sources/OpenBurnBarG2ParserParity/Fixtures/ParserContract/parser-output-golden.json');
  fs.mkdirSync(path.dirname(golden), { recursive: true });
  fs.writeFileSync(golden, `${JSON.stringify(parserOutput(), null, 2)}\n`);
  const candidateClosure = path.join(root, 'candidate/.linux-release/product-proof-closure.json');
  fs.mkdirSync(path.dirname(candidateClosure), { recursive: true });
  fs.writeFileSync(candidateClosure, `${JSON.stringify({
    schemaVersion: 2,
    stage: 'candidate',
    status: 'passed',
    targetHead: HEAD,
    sourceCommit: HEAD,
    git: { commit: HEAD, dirty: false },
    version: '1.2.3'
  })}\n`);
  return { root, golden, candidateClosure };
}

function fakeRun({ generated = parserOutput() } = {}) {
  const bytes = Buffer.from(`${JSON.stringify(generated)}\n`);
  return {
    generated,
    generatedBytes: bytes,
    generatedSha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    stdoutSha256: '1'.repeat(64),
    stderrSha256: '2'.repeat(64),
    command: ['run', '--write-golden']
  };
}

test('producer emits candidate-bound normalized observed output and report', () => {
  const subject = fixture();
  try {
    const output = path.join(subject.root, 'out/linux-platform-evidence.json');
    const report = path.join(subject.root, 'out/producer-report.json');
    const result = captureP39PlatformEvidence({
      repoRoot: subject.root,
      platform: 'linux',
      output,
      report,
      candidateClosure: subject.candidateClosure,
      targetHead: HEAD,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST,
      runtimePlatform: 'linux',
      resolveHead: () => HEAD,
      runProducer: () => fakeRun()
    });
    const document = JSON.parse(fs.readFileSync(output, 'utf8'));
    assert.equal(result.document.id, 'openburnbar-platform-evidence-v1');
    assert.equal(document.targetHead, HEAD);
    assert.equal(document.version, '1.2.3');
    assert.deepEqual(document.candidate, { runId: RUN_ID, artifactDigest: DIGEST });
    assert.equal(document.payload.contract, 'openburnbar-g2-parser-output-v1');
    assert.equal(document.payload.observed.source, 'OpenBurnBarG2ParserParity');
    assert.equal(JSON.parse(fs.readFileSync(report, 'utf8')).status, 'passed');
    assert.equal(fs.readFileSync(subject.golden, 'utf8'), `${JSON.stringify(parserOutput(), null, 2)}\n`);
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('producer refuses to claim the wrong host, head, or candidate closure', () => {
  const subject = fixture();
  try {
    const base = {
      repoRoot: subject.root,
      platform: 'macos',
      output: path.join(subject.root, 'out/evidence.json'),
      candidateClosure: subject.candidateClosure,
      targetHead: HEAD,
      candidateRunId: RUN_ID,
      candidateArtifactDigest: DIGEST,
      resolveHead: () => HEAD,
      runProducer: () => fakeRun()
    };
    assert.throws(() => captureP39PlatformEvidence({ ...base, runtimePlatform: 'linux' }), /cannot run/u);
    assert.throws(() => captureP39PlatformEvidence({ ...base, runtimePlatform: 'darwin', targetHead: 'c'.repeat(40) }), /producer checkout/u);
    const staleClosure = path.join(subject.root, 'candidate/stale.json');
    fs.writeFileSync(staleClosure, `${JSON.stringify({
      schemaVersion: 2, stage: 'candidate', status: 'passed', targetHead: 'c'.repeat(40),
      sourceCommit: 'c'.repeat(40), git: { commit: 'c'.repeat(40), dirty: false }, version: '1.2.3'
    })}\n`);
    assert.throws(() => captureP39PlatformEvidence({ ...base, runtimePlatform: 'darwin', candidateClosure: staleClosure }), /candidate product proof closure/u);
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('G2 producer snapshots and restores the committed golden path', () => {
  const subject = fixture();
  const original = fs.readFileSync(subject.golden);
  try {
    const generated = parserOutput({ providers: ['Codex'] });
    const result = runG2ParserParity({
      repoRoot: subject.root,
      goldenPath: subject.golden,
      runner: (_command, _args) => {
        fs.writeFileSync(subject.golden, `${JSON.stringify(generated)}\n`);
        return { status: 0, stdout: 'Wrote golden to parser-output-golden.json (26 fixtures)', stderr: '' };
      }
    });
    assert.deepEqual(result.generated, generated);
    assert.notEqual(result.generatedSha256, '');
    assert.deepEqual(fs.readFileSync(subject.golden), original);
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('G2 producer restores the golden path after a failed command', () => {
  const subject = fixture();
  const original = fs.readFileSync(subject.golden);
  try {
    assert.throws(() => runG2ParserParity({
      repoRoot: subject.root,
      goldenPath: subject.golden,
      runner: () => ({ status: 1, stdout: '', stderr: 'compile failed' })
    }), /G2 parser producer failed/u);
    assert.deepEqual(fs.readFileSync(subject.golden), original);
  } finally {
    fs.rmSync(subject.root, { recursive: true, force: true });
  }
});

test('parser output validation rejects incomplete or duplicate fixture rows', () => {
  assert.throws(() => validateParserOutput({ formatVersion: 1, providers: [], fixtures: [] }), /complete/u);
  assert.throws(() => validateParserOutput(parserOutput({ fixtures: [
    parserOutput().fixtures[0], parserOutput().fixtures[0]
  ] })), /canonical/u);
  assert.throws(() => validateParserOutput(parserOutput({ fixtures: [{
    ...parserOutput().fixtures[0], usageCount: 2
  }] })), /canonical/u);
});
