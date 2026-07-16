#!/usr/bin/env node
/**
 * Self-test for scripts/ci/check-npm-audit-fail-closed.mjs.
 */

import { AUDIT_DIRS, classifyAuditResult } from "./check-npm-audit-fail-closed.mjs";

let passed = 0;
let failed = 0;

function expect(label, input, wantOk, wantMessagePattern = null) {
  const result = classifyAuditResult({ dir: "fixture", stderr: "", ...input });
  const message = result.messages.join("\n");
  const messageMatches = wantMessagePattern
    ? wantMessagePattern.test(message)
    : true;
  if (result.ok === wantOk && messageMatches) {
    console.log(`  ✓ ${label}`);
    passed += 1;
    return;
  }
  console.error(
    `  ✗ ${label}: got ok=${result.ok}, messages=${JSON.stringify(result.messages)}`,
  );
  failed += 1;
}

console.log("Self-test: check-npm-audit-fail-closed.mjs\n");
const EXPECTED_AUDIT_DIRS = [
  "apps/console",
  "functions",
  "extensions/openburnbar",
  "firestore-rules-tests",
  "services/hermes-realtime-relay",
  "services/hosted-mcp",
  "tools/openburnbar-mcp-remote",
  "packages/libsignal-bridge",
  "packages/libsignal-protocol",
  "packages/signal-envelope-contracts",
  "website",
];

{
  const label = "AUDIT_DIRS covers every package-lock root exactly";
  const sameLength = AUDIT_DIRS.length === EXPECTED_AUDIT_DIRS.length;
  const sameMembers =
    sameLength &&
    EXPECTED_AUDIT_DIRS.every((dir, index) => AUDIT_DIRS[index] === dir);
  if (sameMembers) {
    console.log(`  ✓ ${label}`);
    passed += 1;
  } else {
    console.error(
      `  ✗ ${label}: got ${JSON.stringify(AUDIT_DIRS)}`,
    );
    failed += 1;
  }
}


expect(
  "clean report passes",
  {
    status: 0,
    stdout: JSON.stringify({ vulnerabilities: {} }),
  },
  true,
);

expect(
  "low-only report passes",
  {
    status: 0,
    stdout: JSON.stringify({ vulnerabilities: { demo: { severity: "low" } } }),
  },
  true,
);

expect(
  "high vulnerability fails",
  {
    status: 1,
    stdout: JSON.stringify({ vulnerabilities: { demo: { severity: "high" } } }),
  },
  false,
  /High\/critical vulnerabilities/u,
);

expect(
  "critical vulnerability fails",
  {
    status: 1,
    stdout: JSON.stringify({
      vulnerabilities: { demo: { severity: "critical" } },
    }),
  },
  false,
  /High\/critical vulnerabilities/u,
);

expect(
  "audit service failure with empty output fails closed",
  {
    status: 1,
    stdout: "",
    stderr: "npm ERR! audit endpoint unavailable",
  },
  false,
  /produced no JSON/u,
);

expect(
  "audit service failure with invalid JSON fails closed",
  {
    status: 1,
    stdout: "npm ERR! upstream reset",
    stderr: "npm ERR! upstream reset",
  },
  false,
  /invalid JSON/u,
);

expect(
  "nonzero audit without severe findings fails closed",
  {
    status: 1,
    stdout: JSON.stringify({
      vulnerabilities: { demo: { severity: "moderate" } },
    }),
    stderr: "npm ERR! registry warning",
  },
  false,
  /failing closed/u,
);

expect(
  "spawn failure fails closed",
  {
    status: null,
    stdout: "",
    error: new Error("spawn npm ENOENT"),
  },
  false,
  /could not start/u,
);

console.log(
  `\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`,
);
process.exit(failed === 0 ? 0 : 1);
