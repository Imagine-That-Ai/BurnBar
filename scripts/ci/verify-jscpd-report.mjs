#!/usr/bin/env node

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const reportPath = resolve(
  process.argv[2] ?? "jscpd-report/jscpd-report.json",
);
const minimumTotalSources = Number.parseInt(
  process.env.JSCPD_MIN_TOTAL_SOURCES ?? "100",
  10,
);
const requiredFormats = ["swift", "kotlin", "typescript", "csharp", "rust"];

function fail(message) {
  console.error(`jscpd report verification failed: ${message}`);
  process.exitCode = 1;
}

let report;
try {
  report = JSON.parse(readFileSync(reportPath, "utf8"));
} catch (error) {
  fail(`cannot read ${reportPath}: ${error.message}`);
  process.exit();
}

const formats = report?.statistics?.formats;
const total = report?.statistics?.total;
if (!formats || typeof formats !== "object" || !total) {
  fail("statistics.formats and statistics.total must be present");
  process.exit();
}

for (const format of requiredFormats) {
  const sources = formats[format]?.total?.sources;
  if (!Number.isInteger(sources) || sources < 1) {
    fail(`${format} must analyze at least one source; got ${String(sources)}`);
  }
}

if (!Number.isInteger(total.sources) || total.sources < minimumTotalSources) {
  fail(
    `total analyzed sources must be at least ${minimumTotalSources}; got ${String(total.sources)}`,
  );
}

if (process.exitCode) process.exit();

const counts = requiredFormats
  .map((format) => `${format}=${formats[format].total.sources}`)
  .join(", ");
console.log(
  `jscpd report verification passed: ${counts}, total=${total.sources}, duplication=${total.percentage}%`,
);
