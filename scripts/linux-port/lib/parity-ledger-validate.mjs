/**
 * Pure parity-ledger validation core (extractable for hermetic negatives).
 */
import fs from 'node:fs';
import path from 'node:path';

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

/** Evidence files shared by more than this many rows are flagged as thin/over-shared proof. */
const EVIDENCE_SHARE_WARN_THRESHOLD = 3;

/** Extensions we can scan for a row id (skip binaries like .db/.sqlite/.png). */
const TEXTUAL_EVIDENCE_EXTENSIONS = new Set([
  '.json',
  '.md',
  '.txt',
  '.log',
  '.csv',
  '.yml',
  '.yaml',
  '.html',
  '.ndjson'
]);

/**
 * @param {object} ledger
 * @param {{ allowBlocked?: boolean, currentHead: string, repoRoot: string, ledgerPath?: string }} options
 */
export function validateParityLedger(ledger, options) {
  const allowBlocked = options.allowBlocked === true;
  const failures = [];
  const warnings = [];
  const productParityClaim = ledger.semantics?.productParityClaim === true;

  function fail(message, row = null) {
    failures.push({ message, row: row?.id ?? null });
  }
  function warn(message, row = null) {
    warnings.push({ message, row: row?.id ?? null });
  }

  // Resolve the ledger's own path so a row cannot cite the ledger as its own proof (self-reference).
  const ledgerSelfPath = path.resolve(
    options.repoRoot,
    options.ledgerPath ?? 'docs/linux-port/parity-ledger.json'
  );

  // Cache textual evidence bodies (small JSON/MD/txt) so id-presence checks read each file once.
  const evidenceTextCache = new Map();
  function readEvidenceText(fullPath) {
    if (evidenceTextCache.has(fullPath)) return evidenceTextCache.get(fullPath);
    let text = null;
    try {
      const stat = fs.statSync(fullPath);
      if (stat.isFile() && TEXTUAL_EVIDENCE_EXTENSIONS.has(path.extname(fullPath).toLowerCase())) {
        text = fs.readFileSync(fullPath, 'utf8');
      }
    } catch {
      text = null;
    }
    evidenceTextCache.set(fullPath, text);
    return text;
  }

  if (!ledger.semantics) {
    warn('ledger missing semantics block; treating as historical-infrastructure (not product parity claim).');
  }

  const rows = ledger.rows ?? [];
  if (!rows.length) fail('parity ledger has no rows.');

  // Count how many rows lean on each evidence file to surface thin/over-shared proof (F1).
  const evidenceUsage = new Map();
  for (const row of rows) {
    if (!row.evidencePath) continue;
    const list = evidenceUsage.get(row.evidencePath) ?? [];
    list.push(row.id);
    evidenceUsage.set(row.evidencePath, list);
  }

  const seen = new Set();
  for (const row of rows) {
    if (seen.has(row.id)) fail('duplicate row id', row);
    seen.add(row.id);
    for (const field of requiredFields) {
      if (row[field] === undefined || row[field] === '') fail(`missing required field: ${field}`, row);
    }
    if (!['A', 'B', 'C'].includes(row.tier)) fail('tier must be A, B, or C', row);
    if (!['ready', 'blocked', 'deferred'].includes(row.status)) {
      fail('status must be ready, blocked, or deferred', row);
    }

    const scope = row.scope ?? 'historical-infrastructure';
    if (!['historical-infrastructure', 'product-parity'].includes(scope)) {
      fail('scope must be historical-infrastructure or product-parity', row);
    }

    const evidence = path.join(options.repoRoot, row.evidencePath ?? '');
    const evidenceExists = fs.existsSync(evidence);
    if (!evidenceExists) {
      if (allowBlocked && row.status !== 'ready') {
        warn('blocked row evidence path does not exist yet', row);
      } else {
        fail('evidence path does not exist', row);
      }
    }

    // F2: a row must not cite the ledger itself as its own proof (circular / self-referential).
    if (row.evidencePath && path.resolve(evidence) === ledgerSelfPath) {
      const message = 'evidence path is the ledger itself (self-referential proof)';
      if (allowBlocked) warn(message, row);
      else fail(message, row);
    }

    // F4/F1: a textual evidence file that never names the row it backs is thin proof.
    // Ready rows claim to be proven, so absence is a strict-mode failure; otherwise a warning.
    if (evidenceExists && row.id && path.resolve(evidence) !== ledgerSelfPath) {
      const body = readEvidenceText(evidence);
      if (body !== null && !body.includes(row.id)) {
        const message = `evidence file does not mention row id ${row.id}`;
        if (row.status === 'ready' && !allowBlocked) fail(message, row);
        else warn(message, row);
      }
    }

    if (row.status === 'ready' && row.commit !== ledger.git?.commit) {
      fail('ready row commit does not match ledger git commit', row);
    }

    const staleWhenHeadDiffers =
      row.staleWhenHeadDiffers === true ||
      (scope === 'product-parity' && row.staleWhenHeadDiffers !== false);

    if (
      scope === 'product-parity' &&
      row.status === 'ready' &&
      (row.tier === 'A' || row.tier === 'B') &&
      staleWhenHeadDiffers
    ) {
      const evidenceHead = row.evidenceHead ?? row.validatedAtHead ?? row.commit;
      if (!evidenceHead) {
        fail('product-parity ready row missing evidenceHead/validatedAtHead/commit', row);
      } else if (evidenceHead !== options.currentHead) {
        const message = `product-parity ready row evidence head ${evidenceHead} differs from current HEAD ${options.currentHead}`;
        if (allowBlocked) warn(message, row);
        else fail(message, row);
      }
    }

    if (row.status !== 'ready' && row.tier !== 'C') {
      if (allowBlocked) warn('Tier A/B row is not ready for release promotion', row);
      else fail('Tier A/B row is not ready for release promotion', row);
    }
  }

  // F1: one thin file standing in as proof for many contracts is a false-green smell.
  for (const [evidencePath, ids] of evidenceUsage) {
    if (ids.length > EVIDENCE_SHARE_WARN_THRESHOLD) {
      warn(
        `evidence file ${evidencePath} is shared by ${ids.length} rows (${ids.join(', ')}); ` +
          'existence alone does not prove each row.'
      );
    }
  }

  if (productParityClaim) {
    const productRows = rows.filter(
      (r) => (r.scope ?? 'historical-infrastructure') === 'product-parity'
    );
    if (productRows.length === 0) {
      fail('productParityClaim=true but no product-parity scoped rows exist.');
    }
  }

  return {
    passed: failures.length === 0,
    failures,
    warnings,
    productParityClaim
  };
}
