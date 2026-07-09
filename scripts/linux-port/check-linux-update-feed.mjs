#!/usr/bin/env node
/**
 * VAL-RELEASE / Phase 0: catch public latest-linux.json returning HTML (or non-JSON).
 *
 * Usage:
 *   node scripts/linux-port/check-linux-update-feed.mjs
 *   node scripts/linux-port/check-linux-update-feed.mjs --url https://burnbar.ai/latest-linux.json
 *   node scripts/linux-port/check-linux-update-feed.mjs --allow-missing
 *
 * HTML body is always a hard failure when the resource exists (HTTP 200).
 * With --allow-missing, HTTP 404 is a soft pass (feed not published yet).
 */
import fs from 'node:fs';
import path from 'node:path';
import { repoRoot, writeJson } from './lib/linux-release-common.mjs';
import { classifyFeedResponse, finalizeFeedReport } from './lib/linux-update-feed.mjs';

const args = process.argv.slice(2);
const allowMissing = args.includes('--allow-missing');
const urlIdx = args.indexOf('--url');
const url =
  urlIdx >= 0 && args[urlIdx + 1]
    ? args[urlIdx + 1]
    : 'https://burnbar.ai/latest-linux.json';

const reportPath = path.join(
  repoRoot,
  'docs/linux-port/evidence/mission-002-reanchor/latest-linux-feed-check.json'
);

let report = {
  generatedAt: new Date().toISOString(),
  url,
  allowMissing,
  passed: false,
  httpStatus: null,
  contentType: null,
  bodyKind: null,
  failures: [],
  warnings: []
};

try {
  const res = await fetch(url, {
    redirect: 'follow',
    headers: { Accept: 'application/json, text/plain, */*' }
  });
  report.httpStatus = res.status;
  report.contentType = res.headers.get('content-type');
  const text = await res.text();
  const classified = classifyFeedResponse({
    status: res.status,
    contentType: report.contentType,
    text,
    allowMissing
  });
  report = finalizeFeedReport({
    ...report,
    bodyKind: classified.bodyKind,
    failures: classified.failures,
    warnings: classified.warnings,
    keys: classified.keys
  });
} catch (err) {
  report = finalizeFeedReport({
    ...report,
    bodyKind: 'fetch-error',
    failures: [`fetch failed: ${err instanceof Error ? err.message : String(err)}`],
    warnings: allowMissing
      ? ['Network error under --allow-missing still fails closed (cannot prove feed shape).']
      : []
  });
}

fs.mkdirSync(path.dirname(reportPath), { recursive: true });
writeJson(reportPath, report);
console.log(JSON.stringify(report, null, 2));
process.exit(report.passed ? 0 : 1);
