#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { repoRoot, runStep, writeJson } from './lib/linux-release-common.mjs';

const args = new Set(process.argv.slice(2));
const allowBlocked = args.has('--allow-blocked');
const ledgerPath = path.join(repoRoot, 'docs/linux-port/parity-ledger.json');
const requiredFields = [
  'id',
  'tier',
  'status',
  'evidencePath',
  'command',
  'platform',
  'sourceOracle',
  'acceptedDivergence',
  'owner',
  'promotionCriterion',
  'commit',
  'environment'
];
const failures = [];
const warnings = [];

function fail(message, row = null) {
  failures.push({ message, row: row?.id ?? null });
}

if (!fs.existsSync(ledgerPath)) {
  fail('docs/linux-port/parity-ledger.json is missing.');
} else {
  const ledger = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
  const rows = ledger.rows ?? [];
  if (!rows.length) fail('parity ledger has no rows.');
  const seen = new Set();
  for (const row of rows) {
    if (seen.has(row.id)) fail('duplicate row id', row);
    seen.add(row.id);
    for (const field of requiredFields) {
      if (row[field] === undefined || row[field] === '') fail(`missing required field: ${field}`, row);
    }
    if (!['A', 'B', 'C'].includes(row.tier)) fail('tier must be A, B, or C', row);
    if (!['ready', 'blocked', 'deferred'].includes(row.status)) fail('status must be ready, blocked, or deferred', row);
    const evidence = path.join(repoRoot, row.evidencePath ?? '');
    if (!fs.existsSync(evidence)) {
      if (allowBlocked && row.status !== 'ready') {
        warnings.push({ message: 'blocked row evidence path does not exist yet', row: row.id });
      } else {
        fail('evidence path does not exist', row);
      }
    }
    if (row.status === 'ready' && row.commit !== ledger.git?.commit) {
      fail('ready row commit does not match ledger git commit', row);
    }
    if (row.status !== 'ready' && row.tier !== 'C') {
      const target = allowBlocked ? warnings : failures;
      target.push({ message: 'Tier A/B row is not ready for release promotion', row: row.id });
    }
  }
  const regressionProbe = rows.map((row) => ({ ...row }));
  if (regressionProbe.length > 0) {
    delete regressionProbe[0].evidencePath;
    const hasMissingEvidence = regressionProbe.some((row) => !row.evidencePath);
    if (!hasMissingEvidence) fail('missing-evidence regression probe did not fail.');
  }
}

const git = {
  commit: runStep('git', ['rev-parse', 'HEAD']).stdout.trim(),
  dirtyEntries: runStep('git', ['status', '--porcelain=v1']).stdout.split('\n').filter(Boolean)
};
const report = {
  generatedAt: new Date().toISOString(),
  allowBlocked,
  git,
  passed: failures.length === 0,
  failures,
  warnings
};
writeJson(path.join(repoRoot, 'docs/linux-port/evidence/mission-001-release/parity-ledger-validation.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(failures.length === 0 ? 0 : 1);
