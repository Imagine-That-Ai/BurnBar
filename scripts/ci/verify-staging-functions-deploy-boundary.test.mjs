#!/usr/bin/env node

import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(scriptDir, "..", "..");
const gate = join(scriptDir, "verify-staging-functions-deploy-boundary.mjs");
const fixtureRoot = mkdtempSync(
  join(tmpdir(), "openburnbar-staging-boundary-"),
);
const workflowDir = join(fixtureRoot, ".github", "workflows");
mkdirSync(workflowDir, { recursive: true });

for (const name of ["deploy-staging.yml", "deploy-staging-trusted.yml"]) {
  cpSync(join(repoRoot, ".github", "workflows", name), join(workflowDir, name));
}
const callerPath = join(workflowDir, "deploy-staging.yml");
const trustedPath = join(workflowDir, "deploy-staging-trusted.yml");
const pristineCaller = readFileSync(callerPath, "utf8");
const pristineTrusted = readFileSync(trustedPath, "utf8");

function runGate() {
  return spawnSync(process.execPath, [gate], {
    encoding: "utf8",
    env: { ...process.env, STAGING_DEPLOY_BOUNDARY_ROOT: fixtureRoot },
  });
}

function expectPass(label) {
  const result = runGate();
  if (result.status !== 0) {
    throw new Error(
      `${label}: expected PASS\n${result.stdout}${result.stderr}`,
    );
  }
}

function expectFailure(label, path, source) {
  writeFileSync(path, source);
  const result = runGate();
  if (result.status === 0) throw new Error(`${label}: expected failure`);
  writeFileSync(callerPath, pristineCaller);
  writeFileSync(trustedPath, pristineTrusted);
}

try {
  expectPass("real workflows");
  expectFailure(
    "unpinned reusable workflow",
    callerPath,
    pristineCaller.replace(
      "deploy-staging-trusted.yml@main",
      "deploy-staging-trusted.yml@feature",
    ),
  );
  expectFailure(
    "candidate auth",
    callerPath,
    `${pristineCaller}\n# google-github-actions/auth\n`,
  );
  expectFailure(
    "missing trusted Functions artifact verifier",
    trustedPath,
    pristineTrusted.replace(
      "node trusted/scripts/ci/verify-staging-functions-artifact.mjs",
      "echo verifier-omitted",
    ),
  );
  expectFailure(
    "implicit default Storage bucket lookup",
    trustedPath,
    pristineTrusted.replace(
      `          jq -nc \\
            --arg bucket "\${FIREBASE_PROJECT}.firebasestorage.app" \\
            '{firestore:{rules:"firestore.rules",indexes:"firestore.indexes.json"},storage:[{bucket:$bucket,rules:"storage.rules"}]}' \\
            > "$deploy_root/firebase-rules.json"`,
      `          cat > "$deploy_root/firebase-rules.json" <<'JSON'
          {"firestore":{"rules":"firestore.rules","indexes":"firestore.indexes.json"},"storage":{"rules":"storage.rules"}}
          JSON`,
    ),
  );
  expectFailure(
    "uncompacted Firestore rules deployment",
    trustedPath,
    pristineTrusted.replace(
      `          node scripts/ci/compact-firestore-rules-inplace.mjs \\
            "$deploy_root/firestore.rules"`,
      "          echo firestore-rules-compaction-skipped",
    ),
  );
  expectFailure(
    "hook-free config scan returns failure",
    trustedPath,
    pristineTrusted.replace(
      `          for config in "$deploy_root"/firebase-*.json; do
            if grep -q '"predeploy"' "$config"; then
              echo "::error::Trusted deployment config contains a predeploy hook."
              exit 1
            fi
          done`,
      `          for config in "$deploy_root"/firebase-*.json; do
            grep -q '"predeploy"' "$config" && {
              echo "::error::Trusted deployment config contains a predeploy hook."; exit 1;
            }
          done`,
    ),
  );
  expectFailure(
    "TypeScript declarations retained",
    callerPath,
    pristineCaller.replace(
      `          find "$destination/lib" -type f \\
            \\( -name '*.d.ts' -o -name '*.d.ts.map' \\) -delete`,
      "          echo declarations-retained",
    ),
  );
  expectFailure(
    "certificate documentation retained",
    callerPath,
    pristineCaller.replace(
      '          rm -f "$destination/lib/appstore/certs/README.md"',
      "          echo certificate-documentation-retained",
    ),
  );
  expectFailure(
    "missing staging Hosting build",
    callerPath,
    pristineCaller.replace(
      "npm run build:staging --prefix website",
      "npm run build --prefix website",
    ),
  );
  expectFailure(
    "staging Hosting artifact omits hidden files",
    callerPath,
    pristineCaller.replace(
      `          name: staging-hosting-\${{ github.sha }}
          path: \${{ runner.temp }}/staging-hosting
          include-hidden-files: true`,
      `          name: staging-hosting-\${{ github.sha }}
          path: \${{ runner.temp }}/staging-hosting
          include-hidden-files: false`,
    ),
  );
  expectFailure(
    "staging Functions artifact omits hidden files",
    callerPath,
    pristineCaller.replace(
      `          name: staging-functions-\${{ github.sha }}
          path: \${{ runner.temp }}/staging-functions
          include-hidden-files: true`,
      `          name: staging-functions-\${{ github.sha }}
          path: \${{ runner.temp }}/staging-functions
          include-hidden-files: false`,
    ),
  );
  expectFailure(
    "missing local Functions packages",
    callerPath,
    pristineCaller.replace(
      'cp -R functions/vendor "$destination/vendor"',
      'echo "vendor omitted"',
    ),
  );
  expectFailure(
    "missing Firebase CLI compatibility archive",
    callerPath,
    pristineCaller.replace(
      'test -f "$destination/vendor/openburnbar/brace-expansion-cjs.tgz"',
      'echo "compatibility archive unchecked"',
    ),
  );
  expectFailure(
    "Firebase CLI compatibility source retained",
    callerPath,
    pristineCaller.replace(
      'rm -rf "$destination/vendor/openburnbar/brace-expansion-cjs"',
      'echo "compatibility source retained"',
    ),
  );
  expectFailure(
    "verification after auth",
    trustedPath,
    pristineTrusted
      .replace(
        "Verify bounded candidate artifacts before authentication",
        "TEMP",
      )
      .replace(
        "Authenticate to Google Cloud through trusted-main WIF",
        "Verify bounded candidate artifacts before authentication",
      )
      .replace("TEMP", "Authenticate to Google Cloud through trusted-main WIF"),
  );
  expectFailure(
    "unquoted deploy scope",
    trustedPath,
    pristineTrusted.replace('--only "$deploy_scope"', "--only $deploy_scope"),
  );
  expectFailure(
    "staging dotenv self-truncation",
    trustedPath,
    pristineTrusted.replace(
      `          } > "$env_temp"
          mv "$env_temp" "$env_file"
          trap - EXIT`,
      `          } > "$env_file"
          rm -f "$env_temp"
          trap - EXIT`,
    ),
  );
  expectFailure(
    "raw function_targets forwarded to the trusted deploy",
    callerPath,
    pristineCaller.replace(
      "function_targets: ${{ needs.build-functions-candidate.outputs.resolved_function_targets }}",
      "function_targets: ${{ inputs.function_targets }}",
    ),
  );
  expectFailure(
    "missing blank deploy scope guard",
    trustedPath,
    pristineTrusted.replace(
      `            [[ -n "\${FUNCTION_TARGETS:-}" ]] || {
              echo "::error::deploy_functions requires the resolved function_targets selectors from the candidate build."; exit 1;
            }`,
      "            echo blank-scope-allowed",
    ),
  );
  expectFailure(
    "unscoped functions deploy fallback",
    trustedPath,
    pristineTrusted.replace(
      'deploy_scope="$FUNCTION_TARGETS"',
      `deploy_scope="functions"
          if [[ -n "\${FUNCTION_TARGETS:-}" ]]; then
            deploy_scope="$FUNCTION_TARGETS"
          fi`,
    ),
  );
  expectFailure(
    "target-dependent Hosting deploy",
    trustedPath,
    pristineTrusted.replace("--only hosting", "--only hosting:marketing"),
  );
  expectFailure(
    "missing Hosting rewrite preflight",
    trustedPath,
    pristineTrusted.replace("grep -qx ACTIVE", "cat >/dev/null"),
  );
  expectFailure(
    "unreviewed public rewrite allowlist",
    trustedPath,
    pristineTrusted.replace(
      "[pollCliLink]=us-central1",
      "[unreviewedFunction]=us-central1",
    ),
  );
  expectFailure(
    "overbroad public rewrite IAM role",
    trustedPath,
    pristineTrusted.replace("--role=roles/run.invoker", "--role=roles/editor"),
  );
  expectFailure(
    "missing exact public rewrite count",
    trustedPath,
    pristineTrusted.replace(
      '[[ "$rewrite_count" -eq 4 && "${#reviewed_rewrites[@]}" -eq 0 ]]',
      '[[ "$rewrite_count" -gt 0 ]]',
    ),
  );
  expectFailure(
    "public rewrite IAM after Hosting deploy",
    trustedPath,
    pristineTrusted
      .replace(
        "Grant public invocation only to reviewed Hosting rewrite services",
        "TEMP",
      )
      .replace(
        "Deploy reviewed Hosting artifact",
        "Grant public invocation only to reviewed Hosting rewrite services",
      )
      .replace("TEMP", "Deploy reviewed Hosting artifact"),
  );
  expectFailure(
    "live Hosting verification before deploy",
    trustedPath,
    pristineTrusted
      .replace("Deploy reviewed Hosting artifact", "TEMP")
      .replace(
        "Verify exact staging website deployment",
        "Deploy reviewed Hosting artifact",
      )
      .replace("TEMP", "Verify exact staging website deployment"),
  );
  console.log("PASS: staging deployment boundary self-test.");
} finally {
  rmSync(fixtureRoot, { recursive: true, force: true });
}
