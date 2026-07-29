#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const scriptDir = dirname(fileURLToPath(import.meta.url));
const verifier = join(scriptDir, "verify-staging-functions-artifact.mjs");
const fixtureParent = mkdtempSync(
  join(tmpdir(), "openburnbar-staging-functions-artifact-"),
);
const candidateSha = "7f3aaeb11cff709377653688add71e32612444fd";

function write(path, contents = "fixture\n") {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, contents);
}

function walkFiles(root, directory = root) {
  const files = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const absolutePath = join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkFiles(root, absolutePath));
    } else if (entry.isFile()) {
      files.push(absolutePath);
    }
  }
  return files.sort();
}

function writeManifest(root) {
  const functionsRoot = join(root, "functions");
  const lines = walkFiles(functionsRoot).map((path) => {
    const digest = createHash("sha256")
      .update(readFileSync(path))
      .digest("hex");
    return `${digest}  functions/${relative(functionsRoot, path)}`;
  });
  writeFileSync(join(root, "SHA256SUMS"), `${lines.join("\n")}\n`);
}

function createFixture(label) {
  const root = join(fixtureParent, label);
  mkdirSync(root, { recursive: true });
  writeFileSync(join(root, "CANDIDATE_SHA"), `${candidateSha}\n`);
  write(
    join(root, "functions", "package.json"),
    `${JSON.stringify({ main: "lib/index.js", scripts: {} }, null, 2)}\n`,
  );
  write(
    join(root, "functions", "package-lock.json"),
    `${JSON.stringify({ lockfileVersion: 3 }, null, 2)}\n`,
  );
  write(join(root, "functions", ".env.burnbar-staging"), "STAGING=true\n");
  write(join(root, "functions", "lib", "index.js"), "export {};\n");
  write(join(root, "functions", "lib", "index.js.map"), "{}\n");
  write(join(root, "functions", "lib", "scoped.cjs"), "module.exports = {};\n");
  for (const certificate of [
    "AppleIncRootCertificate.cer",
    "AppleRootCA-G2.cer",
    "AppleRootCA-G3.cer",
  ]) {
    write(
      join(root, "functions", "lib", "appstore", "certs", certificate),
      certificate,
    );
  }
  write(
    join(
      root,
      "functions",
      "vendor",
      "openburnbar",
      "entitlements",
      "lib",
      "index.js",
    ),
    "export {};\n",
  );
  write(
    join(root, "functions", "vendor", "openburnbar", "brace-expansion-cjs.tgz"),
    "reviewed package archive\n",
  );
  writeManifest(root);
  return root;
}

function run(root) {
  return spawnSync(
    process.execPath,
    [verifier, "--artifact-root", root, "--candidate-sha", candidateSha],
    { encoding: "utf8" },
  );
}

function expectPass(label, mutate = () => {}) {
  const root = createFixture(label);
  mutate(root);
  const result = run(root);
  if (result.status !== 0) {
    throw new Error(
      `${label}: expected PASS\n${result.stdout}${result.stderr}`,
    );
  }
}

function expectFailure(label, mutate, { rewriteManifest = true } = {}) {
  const root = createFixture(label);
  mutate(root);
  if (rewriteManifest) writeManifest(root);
  const result = run(root);
  if (result.status === 0) {
    throw new Error(`${label}: expected failure`);
  }
}

try {
  expectPass("valid-runtime-artifact");
  expectFailure("typescript-declaration", (root) => {
    write(join(root, "functions", "lib", "index.d.ts"), "export {};\n");
  });
  expectFailure("typescript-declaration-map", (root) => {
    write(join(root, "functions", "lib", "index.d.ts.map"), "{}\n");
  });
  expectFailure("certificate-readme", (root) => {
    write(
      join(root, "functions", "lib", "appstore", "certs", "README.md"),
      "not runtime data\n",
    );
  });
  expectFailure("unreviewed-certificate", (root) => {
    write(
      join(root, "functions", "lib", "appstore", "certs", "Unknown.cer"),
      "unknown\n",
    );
  });
  expectFailure("unreviewed-vendor", (root) => {
    write(
      join(
        root,
        "functions",
        "vendor",
        "openburnbar",
        "unreviewed",
        "index.js",
      ),
      "export {};\n",
    );
  });
  expectFailure("vendored-package-source", (root) => {
    write(
      join(
        root,
        "functions",
        "vendor",
        "openburnbar",
        "brace-expansion-cjs",
        "index.js",
      ),
      "module.exports = {};\n",
    );
  });
  expectFailure("vendored-package-archive-sibling", (root) => {
    write(
      join(
        root,
        "functions",
        "vendor",
        "openburnbar",
        "brace-expansion-cjs.tgz.sha256",
      ),
      "unreviewed sibling\n",
    );
  });
  expectFailure("executable-package-script", (root) => {
    write(
      join(root, "functions", "package.json"),
      `${JSON.stringify({ main: "lib/index.js", scripts: { postinstall: "echo no" } }, null, 2)}\n`,
    );
  });
  expectFailure("unexpected-top-level-entry", (root) => {
    write(join(root, "EXTRA"), "unexpected\n");
  });
  expectFailure(
    "unmanifested-runtime-file",
    (root) => {
      write(join(root, "functions", "lib", "extra.js"), "export {};\n");
    },
    { rewriteManifest: false },
  );
  expectFailure("candidate-sha-mismatch", (root) => {
    writeFileSync(join(root, "CANDIDATE_SHA"), `${"0".repeat(40)}\n`);
  });
  expectFailure(
    "symbolic-link",
    (root) => {
      const target = join(root, "functions", "lib", "index.js");
      symlinkSync(target, join(root, "functions", "lib", "linked.js"));
    },
    { rewriteManifest: false },
  );
  console.log("PASS: staging Functions artifact verifier self-test.");
} finally {
  rmSync(fixtureParent, { recursive: true, force: true });
}
