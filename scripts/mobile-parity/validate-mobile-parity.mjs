#!/usr/bin/env node
import { collectCandidateFingerprint } from './lib/candidate-fingerprint.mjs';
import { validateMobileParityAtRepo } from './lib/mobile-parity-validate.mjs';
import { repoRoot } from './lib/repo-root.mjs';

const args = new Set(process.argv.slice(2));
const allowBlocked = args.has('--allow-blocked');

const fingerprint = collectCandidateFingerprint(repoRoot);
const result = validateMobileParityAtRepo(repoRoot, {
  allowBlocked,
  currentHead: fingerprint.commitSha,
  fingerprint
});

const report = {
  generatedAt: new Date().toISOString(),
  targetHead: fingerprint.commitSha,
  allowBlocked,
  fingerprint,
  productParityClaim: result.productParityClaim,
  passed: result.passed,
  structuralPassed: result.structuralPassed,
  promotionPassed: result.promotionPassed,
  failures: result.failures,
  structuralFailures: result.structuralFailures,
  promotionFailures: result.promotionFailures,
  warnings: result.warnings
};

console.log(JSON.stringify(report, null, 2));
process.exit(report.passed ? 0 : 1);
