#!/usr/bin/env node
/**
 * Summarize which current artifacts are useful for Linux parity work.
 *
 * This report is deliberately non-certifying. It never writes the canonical
 * parity ledger and never turns a source test or an installed smoke receipt
 * into a product-parity attestation. The strict attestation path still owns
 * promotion decisions.
 */
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { repoRoot } from './lib/linux-release-common.mjs';

export const REPORT_SCHEMA = 'openburnbar.parity.linux-evidence-availability.v1';
export const SOURCE_TEST_SCHEMA = 'openburnbar.parity.linux-source-test-summary.v1';
export const RUNTIME_RECEIPT_SCHEMA = 'openburnbar.parity.linux-installed-runtime-receipt.v1';

const DEFAULTS = Object.freeze({
  ledger: 'docs/linux-port/parity-ledger.json',
  requirements: 'docs/linux-port/product-parity-requirements.json',
  runtimeReceipt: 'docs/linux-port/evidence/parity-audit-2026-07-10/utm-ubuntu-aarch64-installed-runtime-2026-07-14.json',
  output: 'docs/linux-port/evidence/mission-002-reanchor/parity-evidence-availability.json'
});

const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
const COMMIT_PATTERN = /^[a-f0-9]{40}$/u;
const OBSERVED_RUNTIME_REQUIREMENTS = Object.freeze({
  'P-03': ['guiLaunch', 'daemonSpawnedByTrustedLauncher', 'authenticatedDaemonReadiness'],
  'P-33': ['daemonHealthRequestsObserved', 'normalTimeoutExit', 'daemonSIGTERMShutdown', 'temporaryRuntimeCleaned'],
  'P-37': ['environmentTuple']
});

export function parseArguments(argv) {
  const parsed = { ...DEFAULTS, sourceTests: null };
  const flags = new Set(['--ledger', '--requirements', '--runtime-receipt', '--source-tests', '--output']);
  const seen = new Set();
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (!flags.has(flag)) throw new Error(`unknown argument: ${flag}`);
    if (seen.has(flag)) throw new Error(`${flag} may be specified only once`);
    seen.add(flag);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`${flag} requires a value`);
    const key = flag.slice(2).replaceAll('-', '');
    const destination = flag === '--runtime-receipt'
      ? 'runtimeReceipt'
      : flag === '--source-tests'
        ? 'sourceTests'
        : key === 'output'
          ? 'output'
          : key;
    parsed[destination] = value;
    index += 1;
  }
  return parsed;
}

function isInside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function readInput(root, suppliedPath, label) {
  const absolute = path.resolve(root, suppliedPath);
  if (!isInside(root, absolute)) throw new Error(`${label} must be inside the repository: ${suppliedPath}`);
  const stat = fs.lstatSync(absolute);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`${label} must be a regular non-symlink file: ${suppliedPath}`);
  }
  const bytes = fs.readFileSync(absolute);
  let value;
  try {
    value = JSON.parse(bytes.toString('utf8'));
  } catch (error) {
    throw new Error(`${label} is not valid JSON: ${error.message}`);
  }
  return {
    path: path.relative(root, absolute).split(path.sep).join('/'),
    sha256: crypto.createHash('sha256').update(bytes).digest('hex'),
    value
  };
}

function normalizeArchitecture(value) {
  if (value === 'x64' || value === 'amd64') return 'x86_64';
  if (value === 'arm64' || value === 'armv8l') return 'aarch64';
  return value;
}

function normalizeSession(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : null;
}

function desktopMatches(expected, actual) {
  const value = typeof actual === 'string' ? actual.toLowerCase() : '';
  if (expected === 'GNOME') return value.includes('gnome');
  if (expected === 'KDE Plasma') return value.includes('kde') || value.includes('plasma');
  if (expected === 'Sway/wlroots') return value.includes('sway') || value.includes('wlroots');
  return false;
}

function osMatches(expected, actual) {
  const value = typeof actual === 'string' ? actual.toLowerCase() : '';
  if (expected === 'Ubuntu 24.04') return /^ubuntu\s+24\.04(?:\.|\s|$)/u.test(value);
  if (expected === 'Fedora') return value.startsWith('fedora');
  if (expected === 'Arch Linux') return value.startsWith('arch');
  return false;
}

function findEnvironment(requirements, environment) {
  const matrix = Array.isArray(requirements?.minimumSupportMatrix)
    ? requirements.minimumSupportMatrix
    : [];
  return matrix.find((candidate) => (
    osMatches(candidate.os, environment?.os)
    && desktopMatches(candidate.desktop, environment?.desktop)
    && normalizeSession(candidate.session) === normalizeSession(environment?.session)
    && normalizeArchitecture(candidate.architecture) === normalizeArchitecture(environment?.architecture)
  )) ?? null;
}

function summarizeRuntimeReceipt(input, requirements, targetHead) {
  const receipt = input?.value;
  const errors = [];
  const warnings = [];
  if (receipt?.schema !== RUNTIME_RECEIPT_SCHEMA) {
    errors.push(`schema=${receipt?.schema ?? 'missing'} expected=${RUNTIME_RECEIPT_SCHEMA}`);
  }
  if (!COMMIT_PATTERN.test(receipt?.sourceCommit ?? '')) errors.push('sourceCommit must be a 40-character git SHA');
  if (receipt?.sourceCommit && receipt.sourceCommit !== targetHead) {
    errors.push(`sourceCommit=${receipt.sourceCommit} differs from targetHead=${targetHead}`);
  }
  const scope = typeof receipt?.certificationScope === 'string' ? receipt.certificationScope : '';
  const certifying = /\bcertifying\b/u.test(scope) && !/\bnon-certifying\b/u.test(scope);
  if (!certifying) warnings.push('receipt certificationScope is non-certifying');
  const hashes = receipt?.sha256;
  for (const name of ['gui', 'daemon', 'launcher']) {
    if (!SHA256_PATTERN.test(hashes?.[name] ?? '')) errors.push(`sha256.${name} is missing or invalid`);
  }
  const environment = receipt?.environment;
  const environmentId = findEnvironment(requirements, environment)?.id ?? null;
  if (!environmentId) errors.push('receipt environment does not match a declared support-matrix row');
  const checks = receipt?.checks && typeof receipt.checks === 'object' ? receipt.checks : {};
  const positiveChecks = Object.entries(checks)
    .filter(([, value]) => value === true)
    .map(([name]) => name)
    .sort();
  const status = errors.length > 0
    ? (receipt?.sourceCommit && receipt.sourceCommit !== targetHead ? 'stale-non-certifying' : 'invalid')
    : certifying
      ? 'observed-certifying-runtime-input'
      : 'observed-non-certifying';
  return {
    status,
    path: input?.path ?? null,
    sha256: input?.sha256 ?? null,
    sourceCommit: receipt?.sourceCommit ?? null,
    certificationScope: scope || null,
    environmentId,
    environment: environmentId
      ? { os: environment?.os ?? null, desktop: environment?.desktop ?? null, session: environment?.session ?? null, architecture: normalizeArchitecture(environment?.architecture) ?? null }
      : null,
    positiveChecks,
    checkCount: Object.keys(checks).length,
    limitationCount: Array.isArray(receipt?.limitations) ? receipt.limitations.length : 0,
    errors,
    warnings
  };
}

function summarizeSourceTests(input, targetHead) {
  if (!input) {
    return {
      status: 'not-supplied',
      path: null,
      sha256: null,
      sourceCommit: null,
      testCount: null,
      failedCount: null,
      coveredRequirementIds: [],
      errors: ['No machine-readable source-test summary was supplied.']
    };
  }
  const summary = input.value;
  const errors = [];
  if (summary?.schema !== SOURCE_TEST_SCHEMA) {
    errors.push(`schema=${summary?.schema ?? 'missing'} expected=${SOURCE_TEST_SCHEMA}`);
  }
  if (!COMMIT_PATTERN.test(summary?.sourceCommit ?? '')) errors.push('sourceCommit must be a 40-character git SHA');
  if (summary?.sourceCommit && summary.sourceCommit !== targetHead) {
    errors.push(`sourceCommit=${summary.sourceCommit} differs from targetHead=${targetHead}`);
  }
  if (summary?.status !== 'passed') errors.push(`status=${summary?.status ?? 'missing'} expected=passed`);
  if (!Number.isInteger(summary?.testCount) || summary.testCount < 1) errors.push('testCount must be a positive integer');
  if (!Number.isInteger(summary?.failedCount) || summary.failedCount !== 0) errors.push('failedCount must be 0');
  if (!Array.isArray(summary?.coveredRequirementIds) || summary.coveredRequirementIds.some((id) => typeof id !== 'string')) {
    errors.push('coveredRequirementIds must be an array of strings');
  }
  return {
    status: errors.length === 0 ? 'current-passing' : 'not-eligible',
    path: input.path,
    sha256: input.sha256,
    sourceCommit: summary?.sourceCommit ?? null,
    testCount: Number.isInteger(summary?.testCount) ? summary.testCount : null,
    failedCount: Number.isInteger(summary?.failedCount) ? summary.failedCount : null,
    coveredRequirementIds: Array.isArray(summary?.coveredRequirementIds) ? [...summary.coveredRequirementIds].sort() : [],
    command: typeof summary?.command === 'string' ? summary.command : null,
    errors
  };
}

function canonicalRowBlockers(row, runtime, sourceTests) {
  const blockers = [
    `ledger status is ${row.status ?? 'missing'}; this report never changes canonical row status`,
    'canonical product evidence requires a current-head Tier A/B attestation, validator receipts, artifacts, and required environment coverage'
  ];
  if (runtime.status !== 'observed-certifying-runtime-input') {
    blockers.push(`installed runtime receipt is ${runtime.status}`);
  }
  if (sourceTests.status !== 'current-passing') {
    blockers.push(`source-test summary is ${sourceTests.status}`);
  }
  return blockers;
}

function runtimeSignalsForRow(row, runtime) {
  const expectedSignals = OBSERVED_RUNTIME_REQUIREMENTS[row.id] ?? [];
  if (!['observed-non-certifying', 'observed-certifying-runtime-input'].includes(runtime.status)) return [];
  if (!runtime.environmentId || !runtime.positiveChecks.length) return [];
  return expectedSignals.filter((signal) => signal === 'environmentTuple' || runtime.positiveChecks.includes(signal));
}

export function buildEvidenceAvailabilityReport({ ledger, requirements, runtimeReceipt, sourceTests = null, targetHead, generatedAt, checkoutDirty = false }) {
  if (!COMMIT_PATTERN.test(targetHead ?? '')) throw new Error('targetHead must be a 40-character git SHA');
  const runtime = summarizeRuntimeReceipt(runtimeReceipt, requirements, targetHead);
  const source = summarizeSourceTests(sourceTests, targetHead);
  const rows = Array.isArray(ledger?.rows) ? ledger.rows : [];
  const environmentRows = Array.isArray(ledger?.environmentCoverage) ? ledger.environmentCoverage : [];
  const observedRequirementIds = rows
    .filter((row) => runtimeSignalsForRow(row, runtime).length > 0 || source.coveredRequirementIds.includes(row.id))
    .map((row) => row.id)
    .sort();
  const promotionBlockers = [
    'This report is diagnostic and does not certify product parity.',
    `canonical ledger productParityClaim=${ledger?.semantics?.productParityClaim === true}`,
    `${rows.filter((row) => row.status === 'ready').length}/${rows.length} product rows are marked ready in the canonical ledger`,
    `${environmentRows.filter((row) => row.status === 'ready').length}/${environmentRows.length} environment rows are marked ready in the canonical ledger`
  ];
  if (checkoutDirty) promotionBlockers.push('checkout has uncommitted changes; generated availability is not a clean-checkout attestation');
  return {
    schema: REPORT_SCHEMA,
    generatedAt,
    targetHead,
    certificationScope: 'diagnostic-only; source tests and installed smoke receipts are observations, not parity attestations',
    inputs: {
      ledger: { path: ledger?.__input?.path ?? null, sha256: ledger?.__input?.sha256 ?? null },
      requirements: { path: requirements?.__input?.path ?? null, sha256: requirements?.__input?.sha256 ?? null },
      runtimeReceipt: { path: runtime.path, sha256: runtime.sha256 },
      sourceTests: { path: source.path, sha256: source.sha256 }
    },
    canonicalPromotion: {
      status: 'blocked',
      productParityClaim: ledger?.semantics?.productParityClaim === true,
      productRows: { total: rows.length, ready: rows.filter((row) => row.status === 'ready').length, blocked: rows.filter((row) => row.status !== 'ready').length },
      environmentRows: { total: environmentRows.length, ready: environmentRows.filter((row) => row.status === 'ready').length, blocked: environmentRows.filter((row) => row.status !== 'ready').length },
      eligibleProductRowIds: [],
      eligibleEnvironmentRowIds: [],
      blockers: promotionBlockers
    },
    sourceTests: source,
    installedRuntime: runtime,
    observedRequirementIds,
    rows: rows.map((row) => ({
      id: row.id,
      area: row.area ?? null,
      tier: row.tier ?? null,
      ledgerStatus: row.status ?? null,
      observed: runtimeSignalsForRow(row, runtime).length > 0 || source.coveredRequirementIds.includes(row.id),
      runtimeSignals: runtimeSignalsForRow(row, runtime),
      sourceTestCovered: source.coveredRequirementIds.includes(row.id),
      canGenerateCanonicalEvidence: false,
      blockers: canonicalRowBlockers(row, runtime, source)
    })),
    environmentCoverage: environmentRows.map((row) => {
      const observed = row.id === runtime.environmentId;
      return {
        id: row.id,
        ledgerStatus: row.status ?? null,
        observed,
        status: observed ? runtime.status : 'not-observed',
        canGenerateCanonicalEvidence: false,
        blockers: [
          `ledger status is ${row.status ?? 'missing'}`,
          observed
            ? 'installed runtime receipt is not a canonical environment evidence input'
            : 'no installed runtime receipt was supplied for this support-matrix row',
          'canonical environment evidence also requires current-head installed-package and accessibility artifacts'
        ]
      };
    })
  };
}

function gitValue(root, args) {
  try {
    return execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
}

function inputWithMetadata(input, metadata) {
  return { ...input.value, __input: { path: input.path, sha256: input.sha256 }, ...metadata };
}

export function main(argv = process.argv.slice(2), root = repoRoot) {
  const parsed = parseArguments(argv);
  const ledgerInput = readInput(root, parsed.ledger, 'ledger');
  const requirementsInput = readInput(root, parsed.requirements, 'requirements manifest');
  const runtimeInput = readInput(root, parsed.runtimeReceipt, 'runtime receipt');
  const sourceTestsAbsolute = parsed.sourceTests ? path.resolve(root, parsed.sourceTests) : null;
  const sourceTestsExplicit = argv.includes('--source-tests');
  const sourceInput = parsed.sourceTests && (sourceTestsExplicit || fs.existsSync(sourceTestsAbsolute))
    ? readInput(root, parsed.sourceTests, 'source-test summary')
    : null;
  const targetHead = gitValue(root, ['rev-parse', 'HEAD']);
  if (!targetHead || !COMMIT_PATTERN.test(targetHead)) throw new Error('could not resolve a valid repository HEAD');
  const checkoutDirty = Boolean(gitValue(root, ['status', '--porcelain=v1']));
  const report = buildEvidenceAvailabilityReport({
    ledger: inputWithMetadata(ledgerInput, {}),
    requirements: inputWithMetadata(requirementsInput, {}),
    runtimeReceipt: runtimeInput,
    sourceTests: sourceInput,
    targetHead,
    generatedAt: new Date().toISOString(),
    checkoutDirty
  });
  const output = path.resolve(root, parsed.output);
  if (!isInside(root, output)) throw new Error(`output must be inside the repository: ${parsed.output}`);
  fs.mkdirSync(path.dirname(output), { recursive: true });
  fs.writeFileSync(output, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
  process.stdout.write(`${JSON.stringify({ output: path.relative(root, output).split(path.sep).join('/'), schema: report.schema, status: report.canonicalPromotion.status, observedRequirementIds: report.observedRequirementIds }, null, 2)}\n`);
  return report;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`parity evidence availability report failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
