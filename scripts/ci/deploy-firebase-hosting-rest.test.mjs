#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEPLOYER = join(SCRIPT_DIR, "deploy-firebase-hosting-rest.mjs");
const roots = [];
process.on("exit", () => {
  for (const root of roots) rmSync(root, { recursive: true, force: true });
});

function makeArtifact(config) {
  const root = mkdtempSync(join(tmpdir(), "hosting-rest-test-"));
  roots.push(root);
  mkdirSync(join(root, "website", "dist"), { recursive: true });
  mkdirSync(join(root, "apps", "console", "out"), { recursive: true });
  writeFileSync(
    join(root, "website", "dist", "index.html"),
    "<h1>BurnBar</h1>\n",
  );
  writeFileSync(
    join(root, "apps", "console", "out", "index.html"),
    "<h1>Console</h1>\n",
  );
  writeFileSync(
    join(root, ".firebaserc"),
    JSON.stringify(
      {
        projects: { default: "burnbar", staging: "burnbar-staging" },
        targets: {
          burnbar: {
            hosting: {
              marketing: ["burnbar"],
              console: ["burnbar-console"],
            },
          },
          "burnbar-staging": {
            hosting: {
              marketing: ["burnbar-staging"],
              console: ["burnbar-staging-console"],
            },
          },
        },
      },
      null,
      2,
    ),
  );
  writeFileSync(
    join(root, "firebase-hosting.ci.json"),
    JSON.stringify(config, null, 2),
  );
  return root;
}

function run(root) {
  return execFileSync(
    "node",
    [
      DEPLOYER,
      "--project",
      "burnbar",
      "--config",
      join(root, "firebase-hosting.ci.json"),
      "--firebaserc",
      join(root, ".firebaserc"),
      "--dry-run",
    ],
    { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
  );
}

const goodConfig = {
  hosting: [
    {
      target: "marketing",
      public: "website/dist",
      cleanUrls: true,
      trailingSlash: false,
      headers: [{ source: "**", headers: [{ key: "X-Test", value: "ok" }] }],
      redirects: [
        { source: "/docs", destination: "https://example.com", type: 301 },
      ],
      rewrites: [
        {
          source: "/api/**",
          function: {
            functionId: "latestRouterRundown",
            region: "us-central1",
          },
        },
        { source: "**", destination: "/404.html" },
      ],
    },
    {
      target: "console",
      public: "apps/console/out",
      cleanUrls: true,
      trailingSlash: false,
    },
  ],
};

const output = run(makeArtifact(goodConfig));
if (!output.includes("hosting[burnbar] target=marketing files=1")) {
  throw new Error(`marketing target was not dry-run deployed:\n${output}`);
}
if (!output.includes("hosting[burnbar-console] target=console files=1")) {
  throw new Error(`console target was not dry-run deployed:\n${output}`);
}
if (!output.includes("DRY_RUN:")) {
  throw new Error(`dry-run summary missing:\n${output}`);
}

const badConfig = structuredClone(goodConfig);
badConfig.hosting[0].rewrites[0].function.pinTag = true;
try {
  run(makeArtifact(badConfig));
  throw new Error("pinned function rewrite unexpectedly passed");
} catch (error) {
  const stderr = error.stderr?.toString("utf8") ?? "";
  const stdout = error.stdout?.toString("utf8") ?? "";
  if (!stderr.includes("pinTag") && !stdout.includes("pinTag")) {
    throw error;
  }
}

const wrongTargetRoot = makeArtifact(goodConfig);
const wrongFirebaserc = join(wrongTargetRoot, ".firebaserc");
const wrongTargets = JSON.parse(readFileSync(wrongFirebaserc, "utf8"));
wrongTargets.targets.burnbar.hosting.console = ["attacker-controlled-site"];
writeFileSync(wrongFirebaserc, JSON.stringify(wrongTargets));
try {
  run(wrongTargetRoot);
  throw new Error("mismatched production Hosting target unexpectedly passed");
} catch (error) {
  const stderr = error.stderr?.toString("utf8") ?? "";
  if (!stderr.includes("exact reviewed production and staging Hosting target maps"))
    throw error;
}

console.log("PASS: Firebase Hosting REST deployer dry-run fixtures passed.");
