#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const script = join(
  dirname(fileURLToPath(import.meta.url)),
  "verify-jscpd-report.mjs",
);
const root = mkdtempSync(join(tmpdir(), "jscpd-report-test-"));
process.on("exit", () => rmSync(root, { recursive: true, force: true }));

const validReport = {
  statistics: {
    formats: Object.fromEntries(
      ["swift", "kotlin", "typescript"].map((format) => [
        format,
        { total: { sources: 1 } },
      ]),
    ),
    total: { sources: 3, percentage: 2.5 },
  },
};

function run(label, report, expectedExit) {
  const path = join(root, `${label}.json`);
  writeFileSync(path, JSON.stringify(report));
  let actualExit = 0;
  try {
    execFileSync("node", [script, path], {
      env: { ...process.env, JSCPD_MIN_TOTAL_SOURCES: "3" },
      stdio: "pipe",
    });
  } catch (error) {
    actualExit = error.status ?? 1;
  }
  if (actualExit !== expectedExit) {
    console.error(`${label}: expected exit ${expectedExit}, got ${actualExit}`);
    process.exitCode = 1;
  } else {
    console.log(`${label}: passed`);
  }
}

run("valid-multilanguage-report", validReport, 0);
run(
  "missing-swift-format",
  {
    ...validReport,
    statistics: {
      ...validReport.statistics,
      formats: { ...validReport.statistics.formats, swift: undefined },
    },
  },
  1,
);
run(
  "zero-kotlin-sources",
  {
    ...validReport,
    statistics: {
      ...validReport.statistics,
      formats: {
        ...validReport.statistics.formats,
        kotlin: { total: { sources: 0 } },
      },
    },
  },
  1,
);
run(
  "vacuous-total",
  {
    ...validReport,
    statistics: { ...validReport.statistics, total: { sources: 2 } },
  },
  1,
);

if (process.exitCode) process.exit();
console.log("verify-jscpd-report self-test passed");
