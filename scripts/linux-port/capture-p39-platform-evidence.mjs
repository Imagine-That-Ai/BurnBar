#!/usr/bin/env node
/**
 * Run the real lifted parser corpus on one platform and emit a candidate-bound
 * P-39 platform artifact. The G2 executable writes its observed parser output
 * to the committed golden path, so this producer snapshots that path and
 * restores it before returning. No fixture is accepted as observed output.
 */
import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { normalizeArtifact } from './run-platform-differential.mjs';
import {
  P39_ARTIFACT_ID,
  P39_CONTRACT_SCHEMA_VERSION,
  validateBoundArtifact
} from './lib/p39-differential-proof.mjs';

const DEFAULT_REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const DEFAULT_GOLDEN_PATH = 'OpenBurnBarCore/Sources/OpenBurnBarG2ParserParity/Fixtures/ParserContract/parser-output-golden.json';
const HEAD = /^[a-f0-9]{40,64}$/u;
const RUN_ID = /^[1-9][0-9]*$/u;
const DIGEST = /^sha256:[a-f0-9]{64}$/u;
const SHA256 = /^[a-f0-9]{64}$/u;
const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/u;
const PLATFORMS = new Set(['macos', 'linux']);
const PRODUCER_CONTRACT = 'openburnbar-g2-parser-output-v1';
const PRODUCER_SOURCE = 'OpenBurnBarG2ParserParity';
const PRODUCER_INVOCATION = 'swift run --package-path OpenBurnBarCore --disable-automatic-resolution OpenBurnBarG2ParserParity --write-golden';

export const P39_PARSER_CORPUS_PATH = DEFAULT_GOLDEN_PATH;

function exactObject(value, keys, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (actual.length !== expected.length || actual.some((key, index) => key !== expected[index])) {
    throw new Error(`${label} fields must be exactly: ${expected.join(', ')}`);
  }
}

function sha256(bytes) {
  return crypto.createHash('sha256').update(bytes).digest('hex');
}

function stableSha256(value) {
  return sha256(Buffer.from(JSON.stringify(value), 'utf8'));
}

function parseArguments(argv) {
  const required = new Set([
    '--platform', '--output', '--candidate-closure', '--target-head',
    '--candidate-run-id', '--candidate-artifact-digest'
  ]);
  const values = new Map();
  let report = null;
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === '--report') {
      if (report !== null) throw new Error('--report may be specified only once');
      report = argv[++index];
      if (!report || report.startsWith('--')) throw new Error('--report requires a value');
      continue;
    }
    if (!required.has(flag) || values.has(flag)) throw new Error(`invalid argument: ${flag ?? '<missing>'}`);
    const value = argv[++index];
    if (!value || value.startsWith('--')) throw new Error(`${flag} requires a value`);
    values.set(flag, value);
  }
  for (const flag of required) if (!values.has(flag)) throw new Error(`${flag} is required`);
  const platform = values.get('--platform');
  if (!PLATFORMS.has(platform)) throw new Error('--platform must be macos or linux');
  const targetHead = values.get('--target-head');
  if (!HEAD.test(targetHead)) throw new Error('--target-head must be a commit id');
  const candidateRunId = values.get('--candidate-run-id');
  if (!RUN_ID.test(candidateRunId)) throw new Error('--candidate-run-id must be a positive integer');
  const candidateArtifactDigest = values.get('--candidate-artifact-digest');
  if (!DIGEST.test(candidateArtifactDigest)) throw new Error('--candidate-artifact-digest must be a SHA-256 digest');
  return {
    platform,
    output: values.get('--output'),
    report,
    candidateClosure: values.get('--candidate-closure'),
    targetHead,
    candidateRunId,
    candidateArtifactDigest
  };
}

function readJson(file, label) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
}

function readCandidateVersion(candidateClosure, targetHead) {
  const closure = readJson(candidateClosure, 'P-39 candidate product proof closure');
  if (closure?.schemaVersion !== 2 || closure.stage !== 'candidate' || closure.status !== 'passed'
      || closure.targetHead !== targetHead || closure.sourceCommit !== targetHead
      || closure.git?.commit !== targetHead || closure.git?.dirty !== false
      || !VERSION.test(closure.version ?? '')) {
    throw new Error('P-39 candidate product proof closure is not a clean passed artifact at the requested HEAD');
  }
  return closure.version;
}

function currentHead(repoRoot, resolver = spawnSync) {
  const result = resolver('git', ['rev-parse', '--verify', 'HEAD'], {
    cwd: repoRoot,
    encoding: 'utf8'
  });
  if (result.status !== 0) throw new Error(`unable to resolve checkout HEAD: ${(result.stderr || '').trim()}`);
  return result.stdout.trim();
}

export function validateParserOutput(value) {
  exactObject(value, ['fixtures', 'formatVersion', 'providers'], 'G2 parser output');
  if (value.formatVersion !== 1 || !Array.isArray(value.providers) || value.providers.length === 0
      || !Array.isArray(value.fixtures) || value.fixtures.length === 0) {
    throw new Error('G2 parser output has no complete committed fixture corpus');
  }
  const fixtureIDs = new Set();
  for (const fixture of value.fixtures) {
    exactObject(fixture, ['conversationCount', 'fixtureId', 'parser', 'provider', 'usageCount', 'usages'], 'G2 parser fixture');
    if (typeof fixture.fixtureId !== 'string' || fixture.fixtureId.length === 0
        || fixtureIDs.has(fixture.fixtureId) || !Array.isArray(fixture.usages)
        || fixture.usages.length !== fixture.usageCount || fixture.usageCount < 0
        || !Number.isSafeInteger(fixture.conversationCount) || fixture.conversationCount < 0) {
      throw new Error('G2 parser output fixture rows are not canonical');
    }
    fixtureIDs.add(fixture.fixtureId);
  }
  return value;
}

function assertRepositoryCorpus(document, repoRoot) {
  const repository = fs.realpathSync(repoRoot);
  const candidate = path.resolve(repository, document.payload.corpus.source);
  const relative = path.relative(repository, candidate);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error('P-39 producer corpus source escapes the repository');
  }
  const lexical = path.join(repository, document.payload.corpus.source);
  const stat = fs.lstatSync(lexical, { throwIfNoEntry: false });
  if (!stat || !stat.isFile() || stat.isSymbolicLink()) {
    throw new Error('P-39 producer corpus source must be a regular non-symlink file');
  }
  const bytes = fs.readFileSync(lexical);
  if (sha256(bytes) !== document.payload.corpus.baselineSha256) {
    throw new Error('P-39 producer corpus digest does not match the current checkout');
  }
}

export function validateP39ProducerArtifact(document, { repoRoot = null } = {}) {
  exactObject(document?.payload, ['contract', 'corpus', 'observed', 'parserOutput'], 'P-39 producer payload');
  if (document.payload.contract !== PRODUCER_CONTRACT) {
    throw new Error('P-39 producer payload contract is unsupported');
  }
  exactObject(document.payload.corpus, ['baselineSha256', 'source'], 'P-39 producer corpus');
  if (!SHA256.test(document.payload.corpus.baselineSha256 ?? '')) {
    throw new Error('P-39 producer corpus is not the committed parser golden source');
  }
  if (repoRoot !== null) assertRepositoryCorpus(document, repoRoot);
  if (document.payload.corpus.source !== P39_PARSER_CORPUS_PATH) {
    throw new Error('P-39 producer corpus is not the committed parser golden source');
  }
  exactObject(
    document.payload.observed,
    ['generatedSha256', 'invocation', 'normalizedSha256', 'source'],
    'P-39 producer observation'
  );
  if (document.payload.observed.source !== PRODUCER_SOURCE
      || document.payload.observed.invocation !== PRODUCER_INVOCATION
      || !SHA256.test(document.payload.observed.generatedSha256 ?? '')
      || !SHA256.test(document.payload.observed.normalizedSha256 ?? '')) {
    throw new Error('P-39 producer observation is not a real G2 parser run');
  }
  validateParserOutput(document.payload.parserOutput);
  if (stableSha256(normalizeArtifact(document.payload.parserOutput))
      !== document.payload.observed.normalizedSha256) {
    throw new Error('P-39 producer normalized digest does not match parser output');
  }
  return document;
}

function writeJsonAtomic(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}-${Date.now()}`;
  try {
    fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, { encoding: 'utf8', mode: 0o600 });
    fs.renameSync(temporary, file);
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

export function runG2ParserParity({ repoRoot, goldenPath, runner = spawnSync, timeoutMs = 15 * 60 * 1000 }) {
  const temporaryRoot = fs.mkdtempSync(path.join(path.dirname(goldenPath), '.p39-g2-producer-'));
  const backupPath = path.join(temporaryRoot, 'parser-output-golden.json');
  fs.copyFileSync(goldenPath, backupPath);
  const command = [
    'run', '--package-path', 'OpenBurnBarCore', '--disable-automatic-resolution',
    'OpenBurnBarG2ParserParity', '--write-golden'
  ];
  let result;
  try {
    result = runner('swift', command, {
      cwd: repoRoot,
      encoding: 'utf8',
      timeout: timeoutMs,
      maxBuffer: 32 * 1024 * 1024,
      env: { ...process.env }
    });
    if (result.error || result.status !== 0) {
      const reason = result.error?.message ?? `exit ${result.status}`;
      throw new Error(`G2 parser producer failed: ${reason}`);
    }
    if (!/Wrote golden to .*parser-output-golden\.json \(26 fixtures\)/u.test(result.stdout ?? '')) {
      throw new Error('G2 parser producer did not report a fresh 26-fixture golden write');
    }
    const generatedBytes = fs.readFileSync(goldenPath);
    const generated = validateParserOutput(readJson(goldenPath, 'G2 parser output'));
    return {
      generated,
      generatedBytes,
      generatedSha256: sha256(generatedBytes),
      stdoutSha256: sha256(Buffer.from(result.stdout ?? '', 'utf8')),
      stderrSha256: sha256(Buffer.from(result.stderr ?? '', 'utf8')),
      command
    };
  } finally {
    fs.copyFileSync(backupPath, goldenPath);
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

export function captureP39PlatformEvidence({
  repoRoot = DEFAULT_REPO_ROOT,
  platform,
  output,
  report = null,
  candidateClosure,
  targetHead,
  candidateRunId,
  candidateArtifactDigest,
  runtimePlatform = process.platform,
  resolveHead = currentHead,
  runProducer = runG2ParserParity
}) {
  if (!PLATFORMS.has(platform)) throw new Error('P-39 platform must be macos or linux');
  const expectedRuntime = platform === 'macos' ? 'darwin' : 'linux';
  if (runtimePlatform !== expectedRuntime) {
    throw new Error(`P-39 ${platform} producer cannot run on ${runtimePlatform}`);
  }
  if (!HEAD.test(targetHead ?? '')) throw new Error('P-39 target head must be a commit id');
  if (!RUN_ID.test(String(candidateRunId ?? ''))) throw new Error('P-39 candidate run id must be a positive integer');
  if (!DIGEST.test(candidateArtifactDigest ?? '')) throw new Error('P-39 candidate artifact digest must be a SHA-256 digest');
  const repository = fs.realpathSync(repoRoot);
  if (resolveHead(repository) !== targetHead) throw new Error('P-39 producer checkout is not the requested target HEAD');
  const version = readCandidateVersion(path.resolve(candidateClosure), targetHead);
  const goldenPath = path.resolve(repository, DEFAULT_GOLDEN_PATH);
  if (!fs.statSync(goldenPath).isFile()) throw new Error('P-39 parser golden source is missing');
  const baselineBytes = fs.readFileSync(goldenPath);
  const baselineSha256 = sha256(baselineBytes);
  const run = runProducer({ repoRoot: repository, goldenPath });
  if (!Buffer.isBuffer(run.generatedBytes)
      || !SHA256.test(run.generatedSha256 ?? '')
      || sha256(run.generatedBytes) !== run.generatedSha256) {
    throw new Error('P-39 parser producer generated bytes are not hash-bound');
  }
  const normalizedOutput = normalizeArtifact(run.generated);
  const document = {
    schemaVersion: P39_CONTRACT_SCHEMA_VERSION,
    id: P39_ARTIFACT_ID,
    targetHead,
    version,
    candidate: { runId: String(candidateRunId), artifactDigest: candidateArtifactDigest },
    payload: {
      contract: PRODUCER_CONTRACT,
      corpus: {
        source: DEFAULT_GOLDEN_PATH,
        baselineSha256
      },
      observed: {
        source: PRODUCER_SOURCE,
        invocation: PRODUCER_INVOCATION,
        generatedSha256: run.generatedSha256,
        normalizedSha256: stableSha256(normalizedOutput)
      },
      parserOutput: normalizedOutput
    }
  };
  validateP39ProducerArtifact(document, { repoRoot: repository });
  validateBoundArtifact(document, { targetHead, version, candidateRunId, candidateArtifactDigest });
  writeJsonAtomic(path.resolve(output), document);
  const result = {
    schemaVersion: 1,
    id: 'openburnbar-p39-platform-producer-run-v1',
    platform,
    targetHead,
    version,
    candidate: document.candidate,
    command: run.command,
    baselineSha256,
    generatedSha256: run.generatedSha256,
    normalizedSha256: document.payload.observed.normalizedSha256,
    stdoutSha256: run.stdoutSha256,
    stderrSha256: run.stderrSha256,
    status: 'passed'
  };
  if (report) writeJsonAtomic(path.resolve(report), result);
  return { document, report: result, output: path.resolve(output) };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = parseArguments(process.argv.slice(2));
    const result = captureP39PlatformEvidence({
      ...args,
      repoRoot: DEFAULT_REPO_ROOT,
      output: path.resolve(args.output),
      report: args.report ? path.resolve(args.report) : null,
      candidateClosure: path.resolve(args.candidateClosure)
    });
    process.stdout.write(`${JSON.stringify({ output: result.output, status: result.document.status ?? 'passed' }, null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`P-39 platform evidence capture failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
