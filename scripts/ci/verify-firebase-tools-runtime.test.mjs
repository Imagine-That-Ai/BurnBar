import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { verifyFirebaseToolsRuntime } from "./verify-firebase-tools-runtime.mjs";

const MODERN_CONSUMERS = ["glob", "readdir-glob"];
const CALLABLE_CONSUMERS = ["superstatic"];
const MODERN_MINIMATCH_SOURCE = `
class Minimatch {
  hasMagic() { return true; }
}
module.exports = {
  minimatch: () => true,
  Minimatch,
  escape: (value) => value,
  unescape: (value) => value,
};
`;

async function withFirebaseToolsFixture(
  directMinimatchSource,
  run,
  modernMinimatchSource = MODERN_MINIMATCH_SOURCE,
  callableMinimatchSource = directMinimatchSource,
) {
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
    await writeFile(join(minimatchDir, "index.js"), directMinimatchSource);
    const consumerSources = [
      ...MODERN_CONSUMERS.map((name) => [name, modernMinimatchSource]),
      ...CALLABLE_CONSUMERS.map((name) => [name, callableMinimatchSource]),
    ];
    for (const [packageName, minimatchSource] of consumerSources) {
      const packageDir = join(firebaseToolsDir, "node_modules", packageName);
      const packageMinimatchDir = join(packageDir, "node_modules", "minimatch");
      await mkdir(packageMinimatchDir, { recursive: true });
      await writeFile(
        join(packageDir, "package.json"),
        `{"name":"${packageName}","version":"0.0.0-test"}\n`,
      );
      await writeFile(
        join(packageMinimatchDir, "package.json"),
        '{"name":"minimatch","version":"0.0.0-test","main":"index.js"}\n',
      );
      await writeFile(join(packageMinimatchDir, "index.js"), minimatchSource);
    }
    await run(join(firebaseToolsDir, "package.json"));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

const CALLABLE_MINIMATCH_FIXTURE = [
  "module.exports = (value, pattern) => {",
  "  if (pattern === '*.js') return value.endsWith('.js');",
  "  if (pattern === '{index,main}.js') {",
  "    return value === 'index.js' || value === 'main.js';",
  "  }",
  "  return false;",
  "};",
  "",
].join("\n");

test("accepts the callable CommonJS minimatch contract used by Firebase CLI", async () => {
  await withFirebaseToolsFixture(
    CALLABLE_MINIMATCH_FIXTURE,
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

test("rejects downgrading modern Firebase CLI consumers to minimatch v3", async () => {
  await withFirebaseToolsFixture(
    CALLABLE_MINIMATCH_FIXTURE,
    async (packagePath) => {
      assert.throws(
        () => verifyFirebaseToolsRuntime(packagePath),
        /glob resolved an incompatible minimatch export/u,
      );
    },
    "module.exports = () => true;\n",
  );
});

test("rejects upgrading superstatic to a named-only minimatch export", async () => {
  await withFirebaseToolsFixture(
    CALLABLE_MINIMATCH_FIXTURE,
    async (packagePath) => {
      assert.throws(
        () => verifyFirebaseToolsRuntime(packagePath),
        /superstatic resolved an incompatible minimatch export/u,
      );
    },
    MODERN_MINIMATCH_SOURCE,
    MODERN_MINIMATCH_SOURCE,
  );
});

test("rejects a minimatch whose brace expansion crashes at call time", async () => {
  await withFirebaseToolsFixture(
    [
      "module.exports = (value, pattern) => {",
      "  if (pattern.includes('{')) {",
      "    throw new TypeError('expand is not a function');",
      "  }",
      "  return pattern === '*.js' && value.endsWith('.js');",
      "};",
      "",
    ].join("\n"),
    async (packagePath) => {
      assert.throws(
        () => verifyFirebaseToolsRuntime(packagePath),
        /brace expansion is broken at runtime: expand is not a function/u,
      );
    },
  );
});

test("rejects a minimatch whose brace expansion stops matching brace patterns", async () => {
  await withFirebaseToolsFixture(
    "module.exports = (value, pattern) => pattern === '*.js' && value.endsWith('.js');\n",
    async (packagePath) => {
      assert.throws(
        () => verifyFirebaseToolsRuntime(packagePath),
        /brace expansion smoke check did not match/u,
      );
    },
  );
});
