#!/usr/bin/env node
/**
 * Positive controls for scripts/ci/verify-gitleaks-allowlist-boundary.mjs.
 */

import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  findAllowlistBoundaryViolations,
  main,
} from "./verify-gitleaks-allowlist-boundary.mjs";

let passed = 0;
let failed = 0;

function expectViolations(label, configText, expectedCount) {
  const violations = findAllowlistBoundaryViolations(configText);
  if (violations.length === expectedCount) {
    console.log(`  ok   ${label}`);
    passed += 1;
    return;
  }
  console.error(
    `  FAIL ${label}: got ${violations.length}, want ${expectedCount}`,
  );
  failed += 1;
}

console.log("Self-test: verify-gitleaks-allowlist-boundary.mjs\n");

expectViolations(
  "regex-only allowlist is allowed",
  `
[[allowlists]]
description = "regex only"
regexes = ['''demo''']
`,
  0,
);

expectViolations(
  "path-only allowlist is allowed",
  `
[[allowlists]]
description = "path only"
paths = ['''demo\\.txt''']
`,
  0,
);

expectViolations(
  "global path plus regex without condition fails",
  `
[[allowlists]]
description = "missing condition"
regexes = ['''demo''']
paths = ['''demo\\.txt''']
`,
  1,
);

expectViolations(
  "deprecated singular path plus regex without condition fails",
  `
[allowlist]
description = "singular missing condition"
regexes = ['''demo''']
paths = ['''demo\\.txt''']
`,
  1,
);

expectViolations(
  "rule-scoped path plus regex without condition fails",
  `
[[rules]]
id = "demo"
description = "demo"
regex = '''demo'''

[[rules.allowlists]]
description = "rule missing condition"
regexes = ['''demo''']
paths = ['''demo\\.txt''']
`,
  1,
);

expectViolations(
  "path plus stopword without condition fails",
  `
[[allowlists]]
description = "stopword missing condition"
stopwords = ['''placeholder''']
paths = ['''demo\\.txt''']
`,
  1,
);

expectViolations(
  "path plus commit without condition fails",
  `
[[allowlists]]
description = "commit missing condition"
commits = ['''0000000000000000000000000000000000000000''']
paths = ['''demo\\.txt''']
`,
  1,
);

expectViolations(
  "path plus regex with OR fails",
  `
[[allowlists]]
description = "or condition"
condition = "OR"
regexes = ['''demo''']
paths = ['''demo\\.txt''']
`,
  1,
);

expectViolations(
  "path plus regex with AND passes",
  `
[[allowlists]]
description = "and condition"
condition = "AND"
regexes = ['''demo''']
paths = ['''demo\\.txt''']
`,
  0,
);

expectViolations(
  "rule-scoped path plus stopword with AND passes",
  `
[[rules]]
id = "demo"
description = "demo"
regex = '''demo'''

[[rules.allowlists]]
description = "rule and condition"
condition = "AND"
stopwords = ['''placeholder''']
paths = ['''demo\\.txt''']
`,
  0,
);

const fixtureRoot = mkdtempSync(join(tmpdir(), "gitleaks-boundary-test-"));
try {
  const fixturePath = join(fixtureRoot, "gitleaks.toml");
  writeFileSync(
    fixturePath,
    `
[[allowlists]]
description = "and condition"
condition = "AND"
regexes = ['''demo''']
paths = ['''demo\\.txt''']
`,
  );
  const status = main(["node", "verify", fixturePath]);
  if (status === 0) {
    console.log("  ok   CLI main returns success for valid fixture");
    passed += 1;
  } else {
    console.error(`  FAIL CLI main returned ${status} for valid fixture`);
    failed += 1;
  }
} finally {
  rmSync(fixtureRoot, { recursive: true, force: true });
}

console.log(`\n${failed === 0 ? "PASS" : "FAIL"}: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
