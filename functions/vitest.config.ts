import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

const here = new URL(".", import.meta.url);
// 3.5: every package has its own node_modules, but the suite must exercise
// ONE instance of each external (otherwise vi.mock("firebase-admin/...") in
// functions/ cannot intercept functions-sync/src's copy). Pin every runtime
// dependency across all five manifests to this package's copy. Versions are
// pinned identical everywhere, so the copies are interchangeable.
const manifests = [
  "package.json",
  "../packages/functions-shared/package.json",
  "../functions-identity/package.json",
  "../functions-sync/package.json",
  "../functions-media/package.json",
];
const externalNames = new Set<string>();
for (const rel of manifests) {
  const pkg = JSON.parse(readFileSync(new URL(rel, here), "utf8")) as {
    dependencies?: Record<string, string>;
  };
  for (const name of Object.keys(pkg.dependencies ?? {})) {
    if (name !== "@openburnbar/functions-shared") externalNames.add(name);
  }
}
const functionsSharedSrc = fileURLToPath(
  new URL("../packages/functions-shared/src", import.meta.url),
);

export default defineConfig({
  resolve: {
    alias: {
      // Deployed code imports the shared runtime via the vendored package;
      // tests import the same modules via relative paths. Resolve both to
      // the TypeScript source so vi.mock intercepts one instance.
      "@openburnbar/functions-shared": functionsSharedSrc,
    },
    // Dedupe (not alias: aliases bypass exports maps) every external to this
    // package's copy so cross-codebase sources share one module instance.
    dedupe: [...externalNames].sort(),
  },
  test: {
    environment: "node",
    globals: true,
    include: ["src/__tests__/**/*.test.ts"],
    pool: "forks",
    retry: 1,
    coverage: {
      provider: "v8",
      include: ["src/**/*.ts"],
      exclude: ["src/scripts/**", "src/__tests__/**", "**/*.d.ts"],
      reporter: ["text", "json"],
      thresholds: {
        lines: 60,
        functions: 60,
        branches: 50,
        statements: 60,
      },
    },
  },
});
