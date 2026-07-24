#!/usr/bin/env node

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root =
  process.env.STAGING_DEPLOY_BOUNDARY_ROOT ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const callerPath = join(root, ".github", "workflows", "deploy-staging.yml");
const trustedPath = join(
  root,
  ".github",
  "workflows",
  "deploy-staging-trusted.yml",
);

const failures = [];
for (const path of [callerPath, trustedPath]) {
  if (!existsSync(path)) failures.push(`workflow not found: ${path}`);
}
if (failures.length > 0) {
  console.error(`MISCONFIGURED: ${failures.join("; ")}`);
  process.exit(2);
}

const caller = readFileSync(callerPath, "utf8");
const trusted = readFileSync(trustedPath, "utf8");
const requireText = (source, needle, message) => {
  if (!source.includes(needle)) failures.push(message);
};
const reject = (source, pattern, message) => {
  if (pattern.test(source)) failures.push(message);
};

requireText(
  caller,
  "uses: Imagine-That-Ai/BurnBar/.github/workflows/deploy-staging-trusted.yml@main",
  "candidate workflow must delegate deployment to the reusable workflow pinned to main",
);
requireText(
  caller,
  "      id-token: write",
  "caller must explicitly delegate only the OIDC permission needed by the reusable workflow",
);
reject(
  caller,
  /google-github-actions\/auth|firebase-tools.*deploy|\bdeploy\s+--only/u,
  "candidate workflow must not authenticate or deploy directly",
);
requireText(
  caller,
  "npm run test:security --prefix functions",
  "candidate Functions must pass the security suite before packaging",
);
requireText(
  caller,
  "^functions:[A-Za-z][A-Za-z0-9_-]*(,functions:[A-Za-z][A-Za-z0-9_-]*)*$",
  "function_targets must be constrained to explicit Firebase Functions selectors",
);
requireText(
  caller,
  `node scripts/ci/prepare-scoped-functions-deploy.mjs \\
            --targets "$FUNCTION_TARGETS" \\
            --functions-dir functions`,
  "scoped targets must replace the all-functions module graph before artifact upload",
);
reject(
  caller,
  /^\s{10,}[^\n]*\$\{\{\s*inputs\.function_targets\s*\}\}/mu,
  "function_targets must not be interpolated directly into a candidate run script",
);

requireText(
  trusted,
  "  workflow_call:",
  "trusted deployment boundary must be reusable only",
);
requireText(
  trusted,
  "          ref: main",
  "trusted workflow must check out deployment instructions from main",
);
requireText(
  trusted,
  "      - name: Verify bounded candidate artifacts before authentication",
  "candidate artifacts must be bounded and verified before authentication",
);
requireText(
  trusted,
  "npm ci --prefix \"$deploy_root/functions\" --omit=dev --ignore-scripts",
  "candidate package lifecycle scripts must remain disabled",
);
requireText(
  trusted,
  "Authenticate to Google Cloud through trusted-main WIF",
  "trusted reusable workflow must own WIF authentication",
);
requireText(
  trusted,
  '--only "$deploy_scope"',
  "validated Functions deployment scope must remain one quoted argument",
);
reject(
  trusted,
  /\beval\b/u,
  "trusted deployment must not evaluate candidate input as shell code",
);

const verificationIndex = trusted.indexOf(
  "Verify bounded candidate artifacts before authentication",
);
const authIndex = trusted.indexOf(
  "Authenticate to Google Cloud through trusted-main WIF",
);
const deployIndex = trusted.indexOf("Deploy reviewed Functions artifact");
if (
  verificationIndex === -1 ||
  authIndex === -1 ||
  deployIndex === -1 ||
  verificationIndex > authIndex ||
  authIndex > deployIndex
) {
  failures.push(
    "artifact verification must precede WIF authentication and credentialed deployment",
  );
}

if (failures.length > 0) {
  console.error("Staging deployment boundary verification failed:");
  failures.forEach((failure) => console.error(`  - ${failure}`));
  process.exit(1);
}

console.log(
  "PASS: untrusted candidates produce bounded data for the trusted-main staging deploy workflow.",
);
