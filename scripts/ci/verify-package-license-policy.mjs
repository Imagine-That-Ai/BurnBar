#!/usr/bin/env node
import fs from "node:fs";
import { execFileSync } from "node:child_process";

export const PRODUCT_LICENSE = "AGPL-3.0-only";

export const PACKAGE_LICENSE_OVERRIDES = new Map([
  [
    "packages/e2ee-backend-policy/package.json",
    {
      name: "@openburnbar/e2ee-backend-policy",
      license: "MIT",
      reason:
        "MIT upstream-boundary policy package; it must stay libsignal-free.",
      forbiddenDependencies: [
        "@openburnbar/libsignal-bridge",
        "@openburnbar/libsignal-protocol",
        "@openburnbar/signal-envelope-contracts",
        "@signalapp/libsignal-client",
      ],
    },
  ],
]);

const DEPENDENCY_FIELDS = [
  "dependencies",
  "devDependencies",
  "peerDependencies",
  "optionalDependencies",
];

function dependencyNames(pkg) {
  const names = new Set();
  for (const field of DEPENDENCY_FIELDS) {
    const dependencies = pkg[field];
    if (
      !dependencies ||
      typeof dependencies !== "object" ||
      Array.isArray(dependencies)
    )
      continue;
    for (const name of Object.keys(dependencies)) {
      names.add(name);
    }
  }
  return names;
}

export function validatePackageLicensePolicy(packages) {
  const failures = [];
  for (const { file, json } of packages) {
    const override = PACKAGE_LICENSE_OVERRIDES.get(file);
    if (!override) {
      if (json.license !== PRODUCT_LICENSE) {
        failures.push(
          `${file}: expected license ${PRODUCT_LICENSE}, got ${json.license ?? "<missing>"}`,
        );
      }
      continue;
    }

    if (json.name !== override.name) {
      failures.push(
        `${file}: expected package name ${override.name}, got ${json.name ?? "<missing>"}`,
      );
    }
    if (json.license !== override.license) {
      failures.push(
        `${file}: expected license ${override.license} (${override.reason}), got ${json.license ?? "<missing>"}`,
      );
    }

    const deps = dependencyNames(json);
    const forbidden = override.forbiddenDependencies.filter((name) =>
      deps.has(name),
    );
    if (forbidden.length > 0) {
      failures.push(
        `${file}: MIT upstream-boundary package must stay libsignal-free; remove ${forbidden.join(", ")}`,
      );
    }
  }
  return failures;
}

function trackedPackageFiles() {
  return execFileSync(
    "git",
    [
      "ls-files",
      "--cached",
      "--others",
      "--exclude-standard",
      "*package.json",
      ":!:**/node_modules/**",
      ":!:**/package-lock.json",
    ],
    { encoding: "utf8" },
  )
    .trim()
    .split("\n")
    .filter(Boolean);
}

function readPackages(files) {
  return files.map((file) => ({
    file,
    json: JSON.parse(fs.readFileSync(file, "utf8")),
  }));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const failures = validatePackageLicensePolicy(
    readPackages(trackedPackageFiles()),
  );
  if (failures.length > 0) {
    console.error(failures.join("\n"));
    process.exit(1);
  }
}
