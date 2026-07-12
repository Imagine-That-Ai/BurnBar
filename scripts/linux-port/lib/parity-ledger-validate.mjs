/**
 * Pure, fail-closed product parity ledger validation.
 *
 * The tracked ledger declares requirements and evidence commands. Ready rows point at
 * generated attestations that bind their proof to a target HEAD; the tracked ledger
 * never tries to embed the SHA of the commit that contains itself.
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const REQUIRED_ROW_FIELDS = [
  'id',
  'requirementId',
  'tier',
  'status',
  'scope',
  'evidencePath',
  'command',
  'platform',
  'sourceOracle',
  'acceptedDivergence',
  'owner',
  'promotionCriterion',
  'environment'
];

const FORBIDDEN_HEAD_FIELDS = [
  'commit',
  'evidenceHead',
  'validatedAtHead',
  'staleWhenHeadDiffers'
];

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function isInside(parent, child) {
  return child === parent || child.startsWith(`${parent}${path.sep}`);
}

/** Resolve both lexical traversal and symlink escapes without requiring the leaf to exist. */
function resolveConfinedPath(repoRoot, relativePath) {
  const root = fs.realpathSync(repoRoot);
  if (typeof relativePath !== 'string' || relativePath.length === 0) {
    return { error: 'path must be a non-empty string' };
  }
  if (path.isAbsolute(relativePath)) return { error: 'absolute paths are forbidden' };

  const lexical = path.resolve(root, relativePath);
  if (!isInside(root, lexical)) return { error: 'path escapes the repository' };

  let ancestor = lexical;
  while (!fs.existsSync(ancestor)) {
    const parent = path.dirname(ancestor);
    if (parent === ancestor) return { error: 'path has no existing repository ancestor' };
    ancestor = parent;
  }
  const realAncestor = fs.realpathSync(ancestor);
  if (!isInside(root, realAncestor)) return { error: 'path escapes the repository through a symlink' };

  const exists = fs.existsSync(lexical);
  if (exists) {
    const real = fs.realpathSync(lexical);
    if (!isInside(root, real)) return { error: 'path escapes the repository through a symlink' };
    return { path: real, exists: true };
  }
  return { path: lexical, exists: false };
}

function validateAcceptedDivergence(value, fail, row) {
  if (typeof value === 'string') {
    if (value.trim().length === 0) fail('acceptedDivergence must not be empty', row);
    return;
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail('acceptedDivergence must be a string or structured divergence record', row);
    return;
  }
  for (const field of ['reason', 'owner', 'linuxNativeOutcome', 'reviewCriterion']) {
    if (typeof value[field] !== 'string' || value[field].trim().length === 0) {
      fail(`acceptedDivergence.${field} is required`, row);
    }
  }
}

function validateAttestation(attestation, row, options, failPromotion, failStructural) {
  if (attestation?.schemaVersion !== 1) {
    failPromotion('ready evidence attestation schemaVersion must be 1', row);
    return;
  }
  if (attestation.rowId !== row.id || attestation.requirementId !== row.requirementId) {
    failPromotion('ready evidence attestation does not name its row and requirement', row);
  }
  if (attestation.targetHead !== options.currentHead) {
    failPromotion(
      `ready evidence target HEAD ${attestation.targetHead ?? '<missing>'} differs from current HEAD ${options.currentHead}`,
      row
    );
  }
  if (attestation.status !== 'passed') {
    failPromotion('ready evidence attestation status is not passed', row);
  }
  if (!Array.isArray(attestation.artifacts) || attestation.artifacts.length === 0) {
    failPromotion('ready evidence attestation has no artifact hashes', row);
    return;
  }

  const artifactPaths = new Set();
  for (const artifact of attestation.artifacts) {
    if (artifactPaths.has(artifact?.path)) {
      failStructural(`duplicate attested artifact path: ${artifact?.path ?? '<missing>'}`, row);
      continue;
    }
    artifactPaths.add(artifact?.path);
    const resolved = resolveConfinedPath(options.repoRoot, artifact?.path);
    if (resolved.error) {
      failStructural(`attested artifact ${resolved.error}: ${artifact?.path ?? '<missing>'}`, row);
      continue;
    }
    if (!resolved.exists) {
      failPromotion(`attested artifact does not exist: ${artifact.path}`, row);
      continue;
    }
    if (!/^[a-f0-9]{64}$/.test(artifact.sha256 ?? '')) {
      failStructural(`attested artifact has invalid sha256: ${artifact.path}`, row);
      continue;
    }
    if (sha256(resolved.path) !== artifact.sha256) {
      failPromotion(`attested artifact hash mismatch: ${artifact.path}`, row);
    }
  }
}

function validateEnvironmentAttestation(attestation, coverage, options, failPromotion, failStructural) {
  if (attestation?.schemaVersion !== 1 || attestation?.environmentId !== coverage.id) {
    failPromotion(`environment evidence does not name ${coverage.id}.`);
  }
  if (attestation?.targetHead !== options.currentHead) {
    failPromotion(`minimum support environment ${coverage.id} evidence does not match current HEAD.`);
  }
  if (attestation?.status !== 'passed') {
    failPromotion(`minimum support environment ${coverage.id} attestation is not passed.`);
  }
  if (!Array.isArray(attestation?.artifacts) || attestation.artifacts.length === 0) {
    failPromotion(`minimum support environment ${coverage.id} has no attested artifacts.`);
    return;
  }
  const paths = new Set();
  for (const artifact of attestation.artifacts) {
    if (paths.has(artifact?.path)) {
      failStructural(`duplicate ${coverage.id} attested artifact path: ${artifact?.path ?? '<missing>'}.`);
      continue;
    }
    paths.add(artifact?.path);
    const resolved = resolveConfinedPath(options.repoRoot, artifact?.path);
    if (resolved.error) {
      failStructural(`${coverage.id} attested artifact ${resolved.error}: ${artifact?.path ?? '<missing>'}.`);
      continue;
    }
    if (!resolved.exists) {
      failPromotion(`${coverage.id} attested artifact does not exist: ${artifact.path}.`);
      continue;
    }
    if (!/^[a-f0-9]{64}$/.test(artifact.sha256 ?? '')) {
      failStructural(`${coverage.id} attested artifact has invalid sha256: ${artifact.path}.`);
    } else if (sha256(resolved.path) !== artifact.sha256) {
      failPromotion(`${coverage.id} attested artifact hash mismatch: ${artifact.path}.`);
    }
  }
}

/**
 * @param {object} ledger
 * @param {{ allowBlocked?: boolean, currentHead: string, repoRoot: string, ledgerPath?: string, requirements?: object | null }} options
 */
export function validateParityLedger(ledger, options) {
  const structuralFailures = [];
  const promotionFailures = [];
  const warnings = [];
  const productParityClaim = ledger.semantics?.productParityClaim === true;
  const requirements = options.requirements ?? null;

  const structural = (message, row = null) => {
    structuralFailures.push({ message, row: row?.id ?? null });
  };
  const promotion = (message, row = null) => {
    promotionFailures.push({ message, row: row?.id ?? null });
  };
  const warn = (message, row = null) => warnings.push({ message, row: row?.id ?? null });

  if (ledger.schemaVersion !== 2) structural('product parity ledger schemaVersion must be 2.');
  if (ledger.requirementsManifest !== 'docs/linux-port/product-parity-requirements.json') {
    structural('ledger must reference the canonical product parity requirements manifest.');
  }

  const ledgerPath = resolveConfinedPath(
    options.repoRoot,
    options.ledgerPath ?? 'docs/linux-port/parity-ledger.json'
  );
  if (ledgerPath.error) structural(`ledger path ${ledgerPath.error}.`);

  const requirementRows = requirements?.requirements ?? [];
  const requirementIds = new Set();
  if (requirements === null) {
    structural('product parity requirements manifest was not loaded.');
  } else {
    if (requirements.schemaVersion !== 1) {
      structural('product parity requirements schemaVersion must be 1.');
    }
    if (!Array.isArray(requirements.requirements) || requirements.requirements.length === 0) {
      structural('product parity requirements manifest has no requirements.');
    }
    for (const requirement of requirementRows) {
      if (typeof requirement?.id !== 'string' || requirement.id.length === 0) {
        structural('product parity requirement is missing id.');
        continue;
      }
      if (requirementIds.has(requirement.id)) {
        structural(`duplicate product parity requirement id: ${requirement.id}`);
      }
      requirementIds.add(requirement.id);
      if (!['A', 'B'].includes(requirement.minimumEvidenceTier)) {
        structural(`product parity requirement ${requirement.id} has invalid minimumEvidenceTier.`);
      }
    }
  }

  const rows = Array.isArray(ledger.rows) ? ledger.rows : [];
  if (rows.length === 0) structural('parity ledger has no rows.');
  const seenRowIds = new Set();
  const rowsByRequirement = new Map();

  for (const row of rows) {
    if (seenRowIds.has(row.id)) structural('duplicate row id', row);
    seenRowIds.add(row.id);
    for (const field of REQUIRED_ROW_FIELDS) {
      if (row[field] === undefined || row[field] === '') structural(`missing required field: ${field}`, row);
    }
    for (const field of FORBIDDEN_HEAD_FIELDS) {
      if (Object.hasOwn(row, field)) {
        structural(`${field} is forbidden in the tracked product ledger; HEAD binding belongs in generated evidence`, row);
      }
    }
    if (row.scope !== 'product-parity') structural('product ledger rows must use scope product-parity', row);
    if (row.id !== row.requirementId) structural('product ledger row id must equal requirementId', row);
    if (!requirementIds.has(row.requirementId)) {
      structural(`unknown product parity requirement id: ${row.requirementId ?? '<missing>'}`, row);
    }
    if (!['A', 'B'].includes(row.tier)) structural('product ledger tier must be A or B', row);
    if (!['ready', 'blocked'].includes(row.status)) structural('status must be ready or blocked', row);
    validateAcceptedDivergence(row.acceptedDivergence, structural, row);

    const mapped = rowsByRequirement.get(row.requirementId) ?? [];
    mapped.push(row);
    rowsByRequirement.set(row.requirementId, mapped);

    const evidence = resolveConfinedPath(options.repoRoot, row.evidencePath);
    if (evidence.error) {
      structural(`evidence ${evidence.error}: ${row.evidencePath ?? '<missing>'}`, row);
      continue;
    }
    if (ledgerPath.path && evidence.path === ledgerPath.path) {
      structural('evidence path is the ledger itself (self-referential proof)', row);
    }
    if (!evidence.exists) {
      promotion('evidence path does not exist', row);
      if (row.status === 'blocked') warn('blocked row evidence has not been generated', row);
      continue;
    }
    if (!evidence.path.endsWith('.json')) {
      promotion('product evidence must be a generated JSON attestation', row);
      continue;
    }
    let attestation;
    try {
      attestation = JSON.parse(fs.readFileSync(evidence.path, 'utf8'));
    } catch {
      promotion('product evidence is not valid JSON', row);
      continue;
    }
    if (row.status === 'ready') {
      validateAttestation(attestation, row, options, promotion, structural);
    }
  }

  for (const requirement of requirementRows) {
    const candidates = rowsByRequirement.get(requirement.id) ?? [];
    if (candidates.length === 0) {
      structural(`required product capability ${requirement.id} has no ledger row.`);
      continue;
    }
    if (candidates.length > 1) {
      structural(`required product capability ${requirement.id} has ${candidates.length} ledger rows; expected exactly one.`);
      continue;
    }
    const row = candidates[0];
    const permittedTiers = requirement.minimumEvidenceTier === 'A' ? ['A'] : ['A', 'B'];
    if (!permittedTiers.includes(row.tier)) {
      structural(`required product capability ${requirement.id} does not meet Tier ${requirement.minimumEvidenceTier}.`, row);
    }
    if (row.status !== 'ready') promotion(`required product capability ${requirement.id} is blocked.`, row);
  }

  const requiredEnvironments = requirements?.minimumSupportMatrix ?? [];
  const coverageRows = Array.isArray(ledger.environmentCoverage) ? ledger.environmentCoverage : [];
  const coverageById = new Map();
  for (const coverage of coverageRows) {
    if (coverageById.has(coverage.id)) structural(`duplicate environment coverage row: ${coverage.id}`);
    coverageById.set(coverage.id, coverage);
    if (!requiredEnvironments.some((required) => required.id === coverage.id)) {
      structural(`unknown environment coverage row: ${coverage.id}`);
    }
    for (const field of FORBIDDEN_HEAD_FIELDS) {
      if (Object.hasOwn(coverage, field)) {
        structural(`${field} is forbidden in tracked environment coverage: ${coverage.id}`);
      }
    }
    if (!['ready', 'blocked'].includes(coverage.status)) {
      structural(`environment coverage ${coverage.id} status must be ready or blocked.`);
    }
    const evidence = resolveConfinedPath(options.repoRoot, coverage.evidencePath);
    if (evidence.error) {
      structural(`environment coverage ${coverage.id} evidence ${evidence.error}.`);
    } else if (!evidence.exists) {
      promotion(`minimum support environment ${coverage.id} evidence path is missing.`);
    } else if (coverage.status === 'ready') {
      try {
        const attestation = JSON.parse(fs.readFileSync(evidence.path, 'utf8'));
        validateEnvironmentAttestation(attestation, coverage, options, promotion, structural);
      } catch {
        promotion(`minimum support environment ${coverage.id} evidence is not valid JSON.`);
      }
    }
    if (coverage.status !== 'ready') promotion(`minimum support environment ${coverage.id} is blocked.`);
  }
  for (const required of requiredEnvironments) {
    if (!coverageById.has(required.id)) {
      structural(`minimum support environment ${required.id} has no coverage row.`);
    }
  }

  if (!productParityClaim) promotion('product parity claim is false.');

  const structuralPassed = structuralFailures.length === 0;
  const promotionPassed = structuralPassed && promotionFailures.length === 0 && productParityClaim;
  if (productParityClaim && !promotionPassed) {
    structural('productParityClaim=true contradicts the incomplete or invalid evidence graph.');
  }
  const finalStructuralPassed = structuralFailures.length === 0;
  const failures = options.allowBlocked === true
    ? structuralFailures
    : [...structuralFailures, ...promotionFailures];

  return {
    passed: failures.length === 0,
    structuralPassed: finalStructuralPassed,
    promotionPassed: finalStructuralPassed && promotionFailures.length === 0 && productParityClaim,
    productParityClaim,
    failures,
    structuralFailures,
    promotionFailures,
    warnings
  };
}
