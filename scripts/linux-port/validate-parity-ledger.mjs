#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { reanchorEvidenceDir, repoRoot, runStep, writeJson } from './lib/linux-release-common.mjs';
import { validateParityLedger } from './lib/parity-ledger-validate.mjs';

const args = new Set(process.argv.slice(2));
const allowBlocked = args.has('--allow-blocked');
const ledgerPath = path.join(repoRoot, 'docs/linux-port/parity-ledger.json');

const git = {
  commit: runStep('git', ['rev-parse', 'HEAD']).stdout.trim(),
  dirtyEntries: runStep('git', ['status', '--porcelain=v1']).stdout.split('\n').filter(Boolean)
};

let failures = [];
let warnings = [];
let semantics = null;
let productParityClaim = false;

if (!fs.existsSync(ledgerPath)) {
  failures.push({ message: 'docs/linux-port/parity-ledger.json is missing.', row: null });
} else {
  const ledger = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
  semantics = ledger.semantics ?? null;
  productParityClaim = ledger.semantics?.productParityClaim === true;
  const result = validateParityLedger(ledger, {
    allowBlocked,
    currentHead: git.commit,
    repoRoot,
    ledgerPath: path.relative(repoRoot, ledgerPath)
  });
  failures = result.failures;
  warnings = result.warnings;

  // Regression probe: deleting evidencePath from a clone must be detectable.
  const rows = ledger.rows ?? [];
  const regressionProbe = rows.map((row) => ({ ...row }));
  if (regressionProbe.length > 0) {
    delete regressionProbe[0].evidencePath;
    const hasMissingEvidence = regressionProbe.some((row) => !row.evidencePath);
    if (!hasMissingEvidence) {
      failures.push({ message: 'missing-evidence regression probe did not fail.', row: null });
    }
  }
}

const report = {
  generatedAt: new Date().toISOString(),
  allowBlocked,
  git,
  semantics,
  productParityClaim,
  passed: failures.length === 0,
  failures,
  warnings
};

// Write live validation under mission-002 reanchor only — never rewrite sealed mission-001 evidence.
fs.mkdirSync(reanchorEvidenceDir, { recursive: true });
writeJson(path.join(reanchorEvidenceDir, 'parity-ledger-validation.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(failures.length === 0 ? 0 : 1);
