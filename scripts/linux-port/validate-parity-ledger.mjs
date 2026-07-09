#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { reanchorEvidenceDir, repoRoot, runStep, writeJson } from './lib/linux-release-common.mjs';
import { validateParityLedger } from './lib/parity-ledger-validate.mjs';

const args = new Set(process.argv.slice(2));
const allowBlocked = args.has('--allow-blocked');
const ledgerPath = path.join(repoRoot, 'docs/linux-port/parity-ledger.json');
const defaultRequirementsPath = 'docs/linux-port/product-parity-requirements.json';

const git = {
  commit: runStep('git', ['rev-parse', 'HEAD']).stdout.trim(),
  dirtyEntries: runStep('git', ['status', '--porcelain=v1']).stdout.split('\n').filter(Boolean)
};

let result = {
  passed: false,
  structuralPassed: false,
  promotionPassed: false,
  failures: [],
  structuralFailures: [],
  promotionFailures: [],
  warnings: []
};
let semantics = null;
let productParityClaim = false;
let requirementsManifest = null;

if (!fs.existsSync(ledgerPath)) {
  result.structuralFailures.push({ message: 'docs/linux-port/parity-ledger.json is missing.', row: null });
} else {
  const ledger = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'));
  const requirementsRel = ledger.requirementsManifest ?? defaultRequirementsPath;
  const requirementsPath = path.join(repoRoot, requirementsRel);
  if (!fs.existsSync(requirementsPath)) {
    result.structuralFailures.push({ message: `product parity requirements manifest is missing: ${requirementsRel}`, row: null });
  } else {
    requirementsManifest = JSON.parse(fs.readFileSync(requirementsPath, 'utf8'));
  }
  semantics = ledger.semantics ?? null;
  productParityClaim = ledger.semantics?.productParityClaim === true;
  const validation = validateParityLedger(ledger, {
    allowBlocked,
    currentHead: git.commit,
    repoRoot,
    ledgerPath: path.relative(repoRoot, ledgerPath),
    requirements: requirementsManifest
  });
  result = {
    ...validation,
    structuralFailures: [...result.structuralFailures, ...validation.structuralFailures]
  };
  result.structuralPassed = result.structuralFailures.length === 0;
  result.passed = allowBlocked ? result.structuralPassed : result.promotionPassed;
  result.failures = allowBlocked
    ? result.structuralFailures
    : [...result.structuralFailures, ...result.promotionFailures];
}

const report = {
  generatedAt: new Date().toISOString(),
  targetHead: git.commit,
  allowBlocked,
  git,
  semantics,
  productParityClaim,
  requirementsManifest: requirementsManifest?.id ?? null,
  passed: result.passed,
  structuralPassed: result.structuralPassed,
  promotionPassed: result.promotionPassed,
  failures: result.failures,
  structuralFailures: result.structuralFailures,
  promotionFailures: result.promotionFailures,
  warnings: result.warnings
};

// Write live validation under mission-002 reanchor only — never rewrite sealed mission-001 evidence.
fs.mkdirSync(reanchorEvidenceDir, { recursive: true });
writeJson(path.join(reanchorEvidenceDir, 'parity-ledger-validation.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(report.passed ? 0 : 1);
