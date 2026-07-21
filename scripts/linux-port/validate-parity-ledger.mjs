#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { reanchorEvidenceDir, repoRoot, runStep, writeJson } from './lib/linux-release-common.mjs';
import { resolveRepositoryFile } from './lib/product-requirement-attestation.mjs';
import { validateParityLedger } from './lib/parity-ledger-validate.mjs';

const args = new Set(process.argv.slice(2));
const allowBlocked = args.has('--allow-blocked');
const ledgerPath = path.join(repoRoot, 'docs/linux-port/parity-ledger.json');
const defaultRequirementsPath = 'docs/linux-port/product-parity-requirements.json';
const defaultEvidencePolicyPath = 'docs/linux-port/product-parity-evidence-policies.json';

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
  warnings: [],
  validatedAttestations: []
};
let semantics = null;
let productParityClaim = false;
let requirementsManifest = null;
let requirementsDigest = null;
let evidencePolicyManifest = null;

let ledger = null;
try {
  const resolved = resolveRepositoryFile(repoRoot, 'docs/linux-port/parity-ledger.json', 'product parity ledger');
  ledger = JSON.parse(fs.readFileSync(resolved.absolute, 'utf8'));
} catch (error) {
  result.structuralFailures.push({ message: `cannot read canonical product parity ledger: ${error.message}`, row: null });
}

if (ledger !== null) {
  try {
    const resolved = resolveRepositoryFile(repoRoot, defaultRequirementsPath, 'product parity requirements manifest');
    const requirementsBytes = fs.readFileSync(resolved.absolute);
    requirementsDigest = crypto.createHash('sha256').update(requirementsBytes).digest('hex');
    requirementsManifest = JSON.parse(requirementsBytes.toString('utf8'));
  } catch (error) {
    result.structuralFailures.push({ message: `cannot read canonical product parity requirements manifest: ${error.message}`, row: null });
  }
  try {
    const resolved = resolveRepositoryFile(repoRoot, defaultEvidencePolicyPath, 'product parity evidence policy manifest');
    evidencePolicyManifest = JSON.parse(fs.readFileSync(resolved.absolute, 'utf8'));
  } catch (error) {
    result.structuralFailures.push({ message: `cannot read canonical product parity evidence policy manifest: ${error.message}`, row: null });
  }
  semantics = ledger.semantics ?? null;
  productParityClaim = ledger.semantics?.productParityClaim === true;
  const validation = validateParityLedger(ledger, {
    allowBlocked,
    currentHead: git.commit,
    repoRoot,
    ledgerPath: path.relative(repoRoot, ledgerPath),
    requirements: requirementsManifest,
    requirementsDigest,
    evidencePolicies: evidencePolicyManifest
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
  evidencePolicyManifest: evidencePolicyManifest?.id ?? null,
  passed: result.passed,
  structuralPassed: result.structuralPassed,
  promotionPassed: result.promotionPassed,
  failures: result.failures,
  structuralFailures: result.structuralFailures,
  promotionFailures: result.promotionFailures,
  warnings: result.warnings,
  validatedAttestations: result.validatedAttestations
};

// Write live validation under mission-002 reanchor only — never rewrite sealed mission-001 evidence.
fs.mkdirSync(reanchorEvidenceDir, { recursive: true });
writeJson(path.join(reanchorEvidenceDir, 'parity-ledger-validation.json'), report);
console.log(JSON.stringify(report, null, 2));
process.exit(report.passed ? 0 : 1);
