import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { verifyFirebaseToolsRuntime } from "./verify-firebase-tools-runtime.mjs";

async function withFirebaseToolsFixture(minimatchSource, run) {
  const root = await mkdtemp(join(tmpdir(), "firebase-tools-runtime-"));
  try {
    const firebaseToolsDir = join(root, "node_modules", "firebase-tools");
    const minimatchDir = join(firebaseToolsDir, "node_modules", "minimatch");
    await mkdir(minimatchDir, { recursive: true });
    await writeFile(
      join(firebaseToolsDir, "package.json"),
      '{"name":"firebase-tools","version":"0.0.0-test"}\n',
    );
    await writeFile(
      join(minimatchDir, "package.json"),
      '{"name":"minimatch","version":"0.0.0-test","main":"index.js"}\n',
    );
    await writeFile(join(minimatchDir, "index.js"), minimatchSource);
    await run(join(firebaseToolsDir, "package.json"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("accepts the callable CommonJS minimatch contract used by Firebase CLI", async () => {
  await withFirebaseToolsFixture(
    "module.exports = (value, pattern) => pattern === '*.js' && value.endsWith('.js');\n",
    async (packagePath) => {
      assert.doesNotThrow(() => verifyFirebaseToolsRuntime(packagePath));
    },
  );
});

test("rejects the incompatible object export that breaks Functions packaging", async () => {
  await withFirebaseToolsFixture(
    "module.exports = { minimatch: () => true };\n",
    async (packagePath) => {
      assert.throws(
        () => verifyFirebaseToolsRuntime(packagePath),
        /expected a callable CommonJS function/u,
      );
    },
  );
});
