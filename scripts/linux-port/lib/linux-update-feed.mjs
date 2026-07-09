/**
 * Pure helpers for latest-linux.json feed classification (VAL-RELEASE / Phase 0).
 * Hermetic unit tests import from here; the CLI probe wraps network I/O.
 */

export function looksLikeHtml(text, contentType) {
  const ct = (contentType ?? '').toLowerCase();
  if (ct.includes('text/html') || ct.includes('application/xhtml')) return true;
  const head = String(text ?? '')
    .trim()
    .slice(0, 256)
    .toLowerCase();
  return (
    head.startsWith('<!doctype html') ||
    head.startsWith('<html') ||
    head.includes('<head') ||
    head.includes('<body')
  );
}

/**
 * Classify a feed response into a report fragment.
 * @returns {{ bodyKind: string, failures: string[], warnings: string[], passed: boolean, keys?: string[] }}
 */
export function classifyFeedResponse({ status, contentType, text, allowMissing = false }) {
  const failures = [];
  const warnings = [];
  let bodyKind = 'unknown';
  let keys;

  if (status === 404) {
    bodyKind = 'missing';
    if (allowMissing) {
      warnings.push('latest-linux.json is missing (404); allow-missing soft pass.');
    } else {
      failures.push('latest-linux.json returned HTTP 404.');
    }
  } else if (status < 200 || status >= 300) {
    bodyKind = 'http-error';
    failures.push(`latest-linux.json HTTP ${status}`);
  } else if (looksLikeHtml(text, contentType)) {
    // HTML is always a hard failure when the resource exists (even with allow-missing).
    bodyKind = 'html';
    failures.push(
      'latest-linux.json returned HTML (marketing shell) instead of JSON update metadata.'
    );
  } else {
    try {
      const parsed = JSON.parse(text);
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        bodyKind = 'json-non-object';
        failures.push('latest-linux.json parsed but is not a JSON object.');
      } else {
        bodyKind = 'json';
        keys = Object.keys(parsed).slice(0, 20);
      }
    } catch {
      bodyKind = 'non-json';
      failures.push('latest-linux.json body is not valid JSON.');
    }
  }

  return {
    bodyKind,
    failures,
    warnings,
    passed: failures.length === 0,
    keys
  };
}

export function finalizeFeedReport(report) {
  const failures = report.failures ?? [];
  return {
    ...report,
    passed: failures.length === 0
  };
}
