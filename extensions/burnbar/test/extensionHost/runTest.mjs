import { cpSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { runTests } from "@vscode/test-electron";

async function main() {
  const extensionDevelopmentPath = resolve(new URL(".", import.meta.url).pathname, "..", "..");
  const extensionTestsPath = resolve(
    extensionDevelopmentPath,
    ".build",
    "extension-host",
    "test",
    "extensionHost",
    "suite",
    "index.js"
  );
  const fixtureWorkspacePath = resolve(extensionDevelopmentPath, "test", "fixtures", "workspace");
  const tempWorkspacePath = mkdtempSync(join(tmpdir(), "burnbar-extension-host-"));

  cpSync(fixtureWorkspacePath, tempWorkspacePath, { recursive: true });
  process.env.BURNBAR_TEST_WORKSPACE = tempWorkspacePath;

  try {
    await runTests({
      extensionDevelopmentPath,
      extensionTestsPath,
      launchArgs: [
        tempWorkspacePath,
        "--disable-extensions",
        "--skip-welcome",
        "--skip-release-notes"
      ]
    });
  } finally {
    rmSync(tempWorkspacePath, { force: true, recursive: true });
  }
}

main().catch((error) => {
  console.error("BurnBar extension-host tests failed.");
  console.error(error);
  process.exit(1);
});
