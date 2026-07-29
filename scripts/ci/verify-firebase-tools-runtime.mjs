#!/usr/bin/env node

import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const MODERN_MINIMATCH_CONSUMERS = ["glob", "readdir-glob"];

// superstatic (the Firebase Hosting server inside firebase-tools) invokes
// `minimatch(path, glob)` directly, so like firebase-tools itself it needs the
// callable CommonJS contract rather than minimatch 10's named-only exports.
const CALLABLE_MINIMATCH_CONSUMERS = ["superstatic"];

function verifyCallableMinimatchConsumer(
  requireFromFirebaseTools,
  packageName,
) {
  const packagePath = requireFromFirebaseTools.resolve(
    `${packageName}/package.json`,
  );
  const requireFromPackage = createRequire(packagePath);
  const minimatch = requireFromPackage("minimatch");
  if (typeof minimatch !== "function") {
    throw new Error(
      `${packageName} resolved an incompatible minimatch export; expected a callable CommonJS function.`,
    );
  }
  let braceMatched;
  try {
    braceMatched = minimatch("index.js", "{index,main}.js");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(
      `${packageName} minimatch brace expansion is broken at runtime: ${message}`,
    );
  }
  if (!braceMatched) {
    throw new Error(
      `${packageName} minimatch brace expansion smoke check did not match a known-good pattern.`,
    );
  }
}

function verifyModernMinimatchConsumer(requireFromFirebaseTools, packageName) {
  const packagePath = requireFromFirebaseTools.resolve(
    `${packageName}/package.json`,
  );
  const requireFromPackage = createRequire(packagePath);
  const minimatch = requireFromPackage("minimatch");
  const requiredFunctions = [
    ["minimatch", minimatch.minimatch],
    ["Minimatch", minimatch.Minimatch],
    ["Minimatch.prototype.hasMagic", minimatch.Minimatch?.prototype?.hasMagic],
    ["escape", minimatch.escape],
    ["unescape", minimatch.unescape],
  ];
  for (const [member, value] of requiredFunctions) {
    if (typeof value !== "function") {
      throw new Error(
        `${packageName} resolved an incompatible minimatch export; expected ${member} to be a function.`,
      );
    }
  }
}

export function verifyFirebaseToolsRuntime(firebaseToolsPackagePath) {
  if (!firebaseToolsPackagePath) {
    throw new Error("Firebase CLI package.json path is required.");
  }

  const requireFromFirebaseTools = createRequire(firebaseToolsPackagePath);
  const minimatch = requireFromFirebaseTools("minimatch");
  if (typeof minimatch !== "function") {
    throw new Error(
      "Firebase CLI resolved an incompatible minimatch export; expected a callable CommonJS function.",
    );
  }
  if (!minimatch("index.js", "*.js")) {
    throw new Error(
      "Firebase CLI minimatch smoke check did not match a known-good pattern.",
    );
  }
  // Brace expansion resolves lazily inside minimatch, so an incompatible
  // brace-expansion export only crashes when a brace pattern is evaluated.
  // Functions packaging uses brace patterns; exercise one before any auth.
  let braceMatched;
  try {
    braceMatched = minimatch("index.js", "{index,main}.js");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(
      `Firebase CLI minimatch brace expansion is broken at runtime: ${message}`,
    );
  }
  if (!braceMatched) {
    throw new Error(
      "Firebase CLI minimatch brace expansion smoke check did not match a known-good pattern.",
    );
  }
  for (const packageName of MODERN_MINIMATCH_CONSUMERS) {
    verifyModernMinimatchConsumer(requireFromFirebaseTools, packageName);
  }
  for (const packageName of CALLABLE_MINIMATCH_CONSUMERS) {
    verifyCallableMinimatchConsumer(requireFromFirebaseTools, packageName);
  }
}

function isMainModule() {
  return (
    process.argv[1] !== undefined &&
    import.meta.url === pathToFileURL(process.argv[1]).href
  );
}

if (isMainModule()) {
  try {
    verifyFirebaseToolsRuntime(process.argv[2]);
    process.stdout.write("Firebase CLI runtime compatibility check passed.\n");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    process.stderr.write(`::error::${message}\n`);
    process.exitCode = 1;
  }
}
