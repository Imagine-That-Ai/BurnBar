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
if (
  caller.split(
    "Imagine-That-Ai/BurnBar/.github/workflows/deploy-staging-trusted.yml@main",
  ).length !== 2
) {
  failures.push(
    "the protected-main reusable workflow reference must appear exactly once",
  );
}
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
  "npm run build:staging --prefix website",
  "candidate Hosting must use the staging-isolated website build",
);
requireText(
  caller,
  "staging-hosting-${{ github.sha }}",
  "candidate Hosting artifact identity must be bound to the candidate SHA",
);
requireText(
  caller,
  `          name: staging-hosting-\${{ github.sha }}
          path: \${{ runner.temp }}/staging-hosting
          include-hidden-files: true`,
  "candidate Hosting artifact must preserve hidden website files",
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
requireText(
  caller,
  'cp -R functions/vendor "$destination/vendor"',
  "candidate Functions artifact must include its locked local package dependencies",
);
requireText(
  caller,
  'test -f "$destination/vendor/openburnbar/brace-expansion-cjs.tgz"',
  "candidate Functions artifact must retain the reviewed Firebase CLI compatibility archive",
);
requireText(
  caller,
  'rm -rf "$destination/vendor/openburnbar/brace-expansion-cjs"',
  "candidate Functions artifact must remove the non-runtime Firebase CLI compatibility source",
);
requireText(
  caller,
  `          name: staging-functions-\${{ github.sha }}
          path: \${{ runner.temp }}/staging-functions
          include-hidden-files: true`,
  "candidate Functions artifact must preserve hidden runtime files",
);
requireText(
  caller,
  `          find "$destination/lib" -type f \\
            \\( -name '*.d.ts' -o -name '*.d.ts.map' \\) -delete`,
  "candidate Functions artifact must remove non-runtime TypeScript declarations",
);
requireText(
  caller,
  '          rm -f "$destination/lib/appstore/certs/README.md"',
  "candidate Functions artifact must remove non-runtime certificate documentation",
);
requireText(
  trusted,
  `            node trusted/scripts/ci/verify-staging-functions-artifact.mjs \\
              --artifact-root "$functions" \\
              --candidate-sha "$CANDIDATE_SHA"`,
  "trusted workflow must run the tested Functions artifact verifier before authentication",
);
reject(
  caller,
  /^\s{10,}[^\n]*\$\{\{\s*inputs\.function_targets\s*\}\}/mu,
  "function_targets must not be interpolated directly into a candidate run script",
);
requireText(
  caller,
  "function_targets: ${{ needs.build-functions-candidate.outputs.resolved_function_targets }}",
  "trusted deployment must receive the resolved manifest selectors, never a blank all-functions scope",
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
  'npm ci --prefix "$deploy_root/functions" --omit=dev --ignore-scripts',
  "candidate package lifecycle scripts must remain disabled",
);
requireText(
  trusted,
  `          jq -nc \\
            --arg bucket "\${FIREBASE_PROJECT}.firebasestorage.app" \\
            '{firestore:{rules:"firestore.rules",indexes:"firestore.indexes.json"},storage:[{bucket:$bucket,rules:"storage.rules"}]}' \\
            > "$deploy_root/firebase-rules.json"`,
  "trusted rules deployment must bind Storage rules to the explicit staging bucket without a default-bucket lookup",
);
requireText(
  trusted,
  `          node scripts/ci/compact-firestore-rules-inplace.mjs \\
            "$deploy_root/firestore.rules"`,
  "trusted staging deployment must compact Firestore rules before release so deployed bytes match the drift readback",
);
requireText(
  trusted,
  `          for config in "$deploy_root"/firebase-*.json; do
            if grep -q '"predeploy"' "$config"; then
              echo "::error::Trusted deployment config contains a predeploy hook."
              exit 1
            fi
          done`,
  "trusted inert-workspace validation must succeed when every generated Firebase config is hook-free",
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
requireText(
  trusted,
  `          env_temp="$(mktemp "$RUNNER_TEMP/staging-functions-env.XXXXXX")"
          trap 'rm -f "$env_temp"' EXIT
          {
            cat "$functions_dir/.env.burnbar-staging"`,
  "trusted Functions deployment must stage the reviewed dotenv through a temporary file before replacing the project dotenv",
);
requireText(
  trusted,
  `          } > "$env_temp"
          mv "$env_temp" "$env_file"
          trap - EXIT`,
  "trusted Functions deployment must atomically replace the project dotenv without truncating its reviewed source",
);
requireText(
  trusted,
  `            [[ -n "\${FUNCTION_TARGETS:-}" ]] || {
              echo "::error::deploy_functions requires the resolved function_targets selectors from the candidate build."; exit 1;
            }`,
  "trusted Functions deployment must fail closed on a blank deploy scope",
);
reject(
  trusted,
  /deploy_scope="functions"/u,
  "trusted Functions deployment must never fall back to the unscoped functions deploy target",
);
requireText(
  trusted,
  `            --only hosting \\
            --project "$FIREBASE_PROJECT"`,
  "trusted Hosting deployment must deploy the single explicit staging site without target lookup",
);
requireText(
  trusted,
  "node website/scripts/verify-staging-deployment.mjs",
  "trusted Hosting deployment must run the live staging verifier",
);
requireText(
  trusted,
  'gcloud functions describe "$function_id"',
  "trusted Hosting deployment must fail closed unless every rewrite Function is active",
);
requireText(
  trusted,
  "grep -qx ACTIVE",
  "trusted Hosting rewrite preflight must require the ACTIVE state",
);
requireText(
  trusted,
  "Grant public invocation only to reviewed Hosting rewrite services",
  "trusted Hosting deployment must install the reviewed public-invoker bindings",
);
for (const functionId of [
  "burnBarHermesGateway",
  "latestRouterRundown",
  "startCliLink",
  "pollCliLink",
]) {
  requireText(
    trusted,
    `[${functionId}]=us-central1`,
    `trusted Hosting deployment must review ${functionId} in us-central1`,
  );
}
requireText(
  trusted,
  'gcloud run services add-iam-policy-binding "$service_name"',
  "trusted Hosting deployment must bind the resolved Cloud Run rewrite service",
);
requireText(
  trusted,
  "--member=allUsers",
  "trusted Hosting rewrite services must be publicly invokable through Hosting",
);
requireText(
  trusted,
  "--role=roles/run.invoker",
  "trusted Hosting rewrite services must receive only the Cloud Run invoker role",
);
requireText(
  trusted,
  '[[ "$rewrite_count" -eq 4 && "${#reviewed_rewrites[@]}" -eq 0 ]]',
  "trusted Hosting deployment must require the exact reviewed rewrite set",
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
const hostingRewriteIndex = trusted.indexOf(
  "Verify every Hosting rewrite target exists",
);
const hostingIamIndex = trusted.indexOf(
  "Grant public invocation only to reviewed Hosting rewrite services",
);
const hostingDeployIndex = trusted.indexOf("Deploy reviewed Hosting artifact");
const hostingVerifyIndex = trusted.indexOf(
  "Verify exact staging website deployment",
);
if (
  verificationIndex === -1 ||
  authIndex === -1 ||
  deployIndex === -1 ||
  hostingRewriteIndex === -1 ||
  hostingIamIndex === -1 ||
  hostingDeployIndex === -1 ||
  hostingVerifyIndex === -1 ||
  verificationIndex > authIndex ||
  authIndex > deployIndex ||
  deployIndex > hostingRewriteIndex ||
  hostingRewriteIndex > hostingIamIndex ||
  hostingIamIndex > hostingDeployIndex ||
  hostingDeployIndex > hostingVerifyIndex
) {
  failures.push(
    "artifact verification must precede WIF authentication, narrow rewrite IAM, deployment, and live Hosting verification",
  );
}

if (failures.length > 0) {
  console.error("Staging deployment boundary verification failed:");
  failures.forEach((failure) => console.error(`  - ${failure}`));
  process.exit(1);
}

console.log(
  "PASS: untrusted candidates produce bounded rules, Hosting, and Functions data for the trusted-main staging deploy workflow.",
);
