import { cpSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { downloadAndUnzipVSCode, runTests } from "@vscode/test-electron";

const DEFAULT_VSCODE_TEST_VERSION = "1.95.0";

function resolveVSCodeVersion() {
  const requested = process.env.VSCODE_TEST_VERSION?.trim();
  if (!requested) {
    return DEFAULT_VSCODE_TEST_VERSION;
  }

  return requested.startsWith("v") ? requested.slice(1) : requested;
}

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
  const tempWorkspacePath = mkdtempSync(join(tmpdir(), "openburnbar-extension-host-"));

  cpSync(fixtureWorkspacePath, tempWorkspacePath, { recursive: true });
  process.env.BURNBAR_TEST_WORKSPACE = tempWorkspacePath;

  try {
    // Always pass an explicit version to avoid flaky "stable releases" API lookups in CI.
    const vscodeVersion = resolveVSCodeVersion();
    const downloadedExecutablePath = await downloadAndUnzipVSCode(vscodeVersion);
    const vscodeExecutablePath = process.platform === "darwin"
      ? resolve(downloadedExecutablePath, "..", "..", "Resources", "app", "bin", "code")
      : downloadedExecutablePath;

    await runTests({
      extensionDevelopmentPath,
      extensionTestsPath,
      vscodeExecutablePath
    });
  } finally {
    rmSync(tempWorkspacePath, { force: true, recursive: true });
  }
}

main().catch((error) => {
  console.error("OpenBurnBar extension-host tests failed.");
  console.error(error);
  process.exit(1);
});
