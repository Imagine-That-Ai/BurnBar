const IDENTITY_FIELDS = ['architecture', 'desktop', 'environmentId', 'session'];

function normalizeArchitecture(value) {
  if (value === 'x64' || value === 'amd64') return 'x86_64';
  if (value === 'arm64' || value === 'armv8l') return 'aarch64';
  return value;
}

function normalizeSession(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : value;
}

function desktopMatches(expected, detected) {
  const value = typeof detected === 'string' ? detected.toLowerCase() : '';
  if (expected === 'GNOME') return value.includes('gnome');
  if (expected === 'KDE Plasma') return value.includes('kde') || value.includes('plasma');
  if (expected === 'Sway/wlroots') return value.includes('sway');
  return false;
}

function exactObjectFields(value, fields) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return false;
  const actual = Object.keys(value).sort();
  return actual.length === fields.length && fields.every((field, index) => actual[index] === field);
}

/**
 * Matrix evidence must carry its own row identity. A current-HEAD hash alone
 * cannot stop an x86_64 artifact from being attached to an aarch64 or desktop
 * session row, so this contract is checked before the artifact is admitted.
 */
export function validateEnvironmentEvidenceIdentity(expected, evidence) {
  const errors = [];
  const identity = evidence?.identity;
  if (!exactObjectFields(identity, IDENTITY_FIELDS)) {
    errors.push(`identity fields must be exactly: ${IDENTITY_FIELDS.join(', ')}`);
    return { passed: false, errors };
  }

  if (identity.environmentId !== expected?.id) {
    errors.push(`environmentId=${identity.environmentId ?? 'missing'} expected=${expected?.id ?? 'missing'}`);
  }
  const architecture = normalizeArchitecture(identity.architecture);
  if (architecture !== expected?.architecture) {
    errors.push(`architecture=${architecture ?? 'missing'} expected=${expected?.architecture ?? 'missing'}`);
  }
  const session = normalizeSession(identity.session);
  if (session !== normalizeSession(expected?.session)) {
    errors.push(`session=${session ?? 'missing'} expected=${normalizeSession(expected?.session) ?? 'missing'}`);
  }
  if (!desktopMatches(expected?.desktop, identity.desktop)) {
    errors.push(`desktop=${identity.desktop ?? 'missing'} expected=${expected?.desktop ?? 'missing'}`);
  }
  return { passed: errors.length === 0, errors };
}

export function validateEnvironmentEvidenceInput(expected, evidence, targetHead) {
  const commit = evidence?.targetHead ?? evidence?.git?.commit ?? evidence?.commit ?? null;
  const identity = expected
    ? validateEnvironmentEvidenceIdentity(expected, evidence)
    : { passed: true, errors: [] };
  const errors = [];
  if (evidence?.passed !== true) errors.push(`passed=${evidence?.passed}`);
  if (commit !== targetHead) errors.push(`commit=${commit ?? 'missing'}`);
  errors.push(...identity.errors);
  return { passed: errors.length === 0, commit, errors };
}
