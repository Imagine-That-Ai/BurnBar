#!/usr/bin/env node

import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

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
