#!/usr/bin/env node

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root =
  process.env.STAGING_DEPLOY_BOUNDARY_ROOT ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const workflowPath = join(root, ".github", "workflows", "deploy-staging.yml");
const targetManifestPath = join(
  root,
  "functions",
  "staging-deploy-targets.json",
);

if (!existsSync(workflowPath)) {
  console.error(`MISCONFIGURED: workflow not found: ${workflowPath}`);
  process.exit(2);
}
if (!existsSync(targetManifestPath)) {
  console.error(
    `MISCONFIGURED: staging target manifest not found: ${targetManifestPath}`,
  );
  process.exit(2);
}

const source = readFileSync(workflowPath, "utf8");
const failures = [];
const requireText = (needle, message) => {
  if (!source.includes(needle)) failures.push(message);
};
const reject = (pattern, message) => {
  if (pattern.test(source)) failures.push(message);
};

requireText(
  "      function_targets:\n",
  "workflow_dispatch must expose an explicit function_targets input",
);
requireText(
  "      FUNCTION_TARGETS: ${{ github.event.inputs.function_targets }}",
  "function_targets must enter shell only through the job environment",
);
requireText(
  "^functions:[A-Za-z][A-Za-z0-9_-]*(,functions:[A-Za-z][A-Za-z0-9_-]*)*$",
  "function_targets must be constrained to explicit Firebase Functions selectors",
);
requireText(
  'TEMP_ENV_FILE="$(mktemp "$RUNNER_TEMP/openburnbar-functions-env.XXXXXX")"',
  "runtime config must be assembled in a runner-temporary file",
);
requireText(
  '} > "$TEMP_ENV_FILE"\n          mv "$TEMP_ENV_FILE" "$ENV_FILE"',
  "runtime config must be atomically moved over the Firebase env file",
);
requireText(
  'deploy_scope="functions"',
  "an empty function_targets input must retain the explicit all-functions default",
);
requireText(
  'deploy_scope="$FUNCTION_TARGETS"',
  "validated function_targets must select the requested deployment scope",
);
requireText(
  `node scripts/ci/prepare-scoped-functions-deploy.mjs \\
            --targets "$FUNCTION_TARGETS" \\
            --functions-dir functions`,
  "scoped targets must replace the all-functions module graph before authentication",
);
requireText(
  '--only "$deploy_scope"',
  "Firebase deploy scope must remain a single quoted argument",
);
reject(
  /\}\s*>\s*"\$ENV_FILE"/u,
  "staging config must never be read from and redirected directly onto the same file",
);
reject(
  /\beval\b/u,
  "staging deployment must not evaluate function_targets as shell code",
);
reject(
  /^\s{10,}[^\n]*\$\{\{\s*github\.event\.inputs\.function_targets\s*\}\}/mu,
  "function_targets must not be interpolated directly into a run script",
);

const requiredCommercialTargets = {
  appStoreServerNotificationsV2: {
    module: "./appstore/notifications.js",
    export: "appStoreServerNotificationsV2",
  },
  beginEntitlementBinding: {
    module: "./appstore/callable.js",
    export: "beginEntitlementBinding",
  },
  createStripeBurnBarProCheckoutSession: {
    module: "./callables/stripe.js",
    export: "createStripeBurnBarProCheckoutSession",
  },
  createStripeBurnBarProPortalSession: {
    module: "./callables/stripe.js",
    export: "createStripeBurnBarProPortalSession",
  },
  googlePlayDeveloperNotifications: {
    module: "./googlePlayRtdn.js",
    export: "googlePlayDeveloperNotifications",
  },
  reconcileHostedEntitlementsDaily: {
    module: "./appstore/scheduled.js",
    export: "reconcileHostedEntitlementsDaily",
  },
  restoreHostedQuotaEntitlement: {
    module: "./appstore/callable.js",
    export: "restoreHostedQuotaEntitlement",
  },
  stripeBurnBarProWebhook: {
    module: "./callables/stripe.js",
    export: "stripeBurnBarProWebhook",
  },
  verifyCloudProTopUp: {
    module: "./appstore/callable.js",
    export: "verifyCloudProTopUp",
  },
  verifyGooglePlayBurnBarProSubscription: {
    module: "./callables/stripe.js",
    export: "verifyGooglePlayBurnBarProSubscription",
  },
  verifyGooglePlayCloudProTopUp: {
    module: "./callables/stripe.js",
    export: "verifyGooglePlayCloudProTopUp",
  },
  verifyHostedQuotaEntitlement: {
    module: "./appstore/callable.js",
    export: "verifyHostedQuotaEntitlement",
  },
};
let targetManifest;
try {
  targetManifest = JSON.parse(readFileSync(targetManifestPath, "utf8"));
} catch (error) {
  failures.push(
    `staging target manifest must be valid JSON: ${
      error instanceof Error ? error.message : String(error)
    }`,
  );
}
for (const [targetName, expected] of Object.entries(
  requiredCommercialTargets,
)) {
  const actual = targetManifest?.targets?.[targetName];
  if (
    actual?.module !== expected.module ||
    actual?.export !== expected.export
  ) {
    failures.push(
      `commercial staging target ${targetName} must bind ${expected.module}#${expected.export}`,
    );
  }
}

const functionsJobIndex = source.indexOf("  functions-staging:");
const scopeIndex = source.indexOf(
  "prepare-scoped-functions-deploy.mjs",
  functionsJobIndex,
);
const authIndex = source.indexOf(
  "Authenticate to Google Cloud (staging WIF/OIDC only)",
  functionsJobIndex,
);
const deployIndex = source.indexOf(
  "Deploy Cloud Functions (staging)",
  functionsJobIndex,
);
if (
  functionsJobIndex === -1 ||
  authIndex === -1 ||
  deployIndex === -1 ||
  authIndex > deployIndex
) {
  failures.push(
    "WIF/OIDC authentication must precede the credentialed Functions deploy",
  );
}
if (scopeIndex === -1 || scopeIndex > authIndex) {
  failures.push(
    "the scoped Functions entrypoint must be prepared before WIF/OIDC credentials exist",
  );
}

if (failures.length > 0) {
  console.error("Staging Functions deploy boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log(
  "PASS: staging Functions deploy preserves config and isolates scoped targets before auth.",
);
