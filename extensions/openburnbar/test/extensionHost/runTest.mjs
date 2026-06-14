import { cpSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { downloadAndUnzipVSCode, runTests } from "@vscode/test-electron";

const DEFAULT_VSCODE_TEST_VERSION = "1.95.0";
const DEFAULT_VSCODE_DOWNLOAD_TIMEOUT_MS = 120_000;
const DEFAULT_VSCODE_DOWNLOAD_ATTEMPTS = 3;
const TRANSIENT_VSCODE_DOWNLOAD_ERRORS = [
  "aborted",
  "ECONNRESET",
  "ECONNREFUSED",
  "EAI_AGAIN",
  "ENOTFOUND",
  "ETIMEDOUT",
  "socket hang up"
];

function resolveVSCodeVersion() {
  const requested = process.env.VSCODE_TEST_VERSION?.trim();
  if (!requested) {
    return DEFAULT_VSCODE_TEST_VERSION;
  }

  return requested.startsWith("v") ? requested.slice(1) : requested;
}

function resolveVSCodeDownloadTimeout() {
  const requested = process.env.VSCODE_TEST_DOWNLOAD_TIMEOUT_MS?.trim();
  if (!requested) {
    return DEFAULT_VSCODE_DOWNLOAD_TIMEOUT_MS;
  }

  const timeout = Number.parseInt(requested, 10);
  if (!Number.isFinite(timeout) || timeout <= 0) {
    throw new Error(`Invalid VSCODE_TEST_DOWNLOAD_TIMEOUT_MS: ${requested}`);
  }

  return timeout;
}

function resolveVSCodeDownloadAttempts() {
  const requested = process.env.VSCODE_TEST_DOWNLOAD_ATTEMPTS?.trim();
  if (!requested) {
    return DEFAULT_VSCODE_DOWNLOAD_ATTEMPTS;
  }

  const attempts = Number.parseInt(requested, 10);
  if (!Number.isFinite(attempts) || attempts <= 0) {
    throw new Error(`Invalid VSCODE_TEST_DOWNLOAD_ATTEMPTS: ${requested}`);
  }

  return attempts;
}

function errorText(error) {
  const parts = [];
  let current = error;

  while (current && typeof current === "object") {
    if ("code" in current) {
      parts.push(String(current.code));
    }
    if ("message" in current) {
      parts.push(String(current.message));
    }
    current = current.cause;
  }

  if (parts.length === 0) {
    parts.push(String(error));
  }

  return parts.join(" ");
}

function isTransientVSCodeDownloadError(error) {
  const text = errorText(error);
  return TRANSIENT_VSCODE_DOWNLOAD_ERRORS.some((pattern) => text.includes(pattern));
}

function sleep(ms) {
  return new Promise((resolveSleep) => {
    setTimeout(resolveSleep, ms);
  });
}

async function downloadVSCodeWithRetry(options) {
  const attempts = resolveVSCodeDownloadAttempts();

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await downloadAndUnzipVSCode(options);
    } catch (error) {
      const canRetry = attempt < attempts && isTransientVSCodeDownloadError(error);
      if (!canRetry) {
        throw error;
      }

      const delayMs = attempt * 5_000;
      console.warn(
        `VS Code download failed with a transient network error; retrying in ${delayMs / 1000}s ` +
          `(${attempt}/${attempts}).`
      );
      await sleep(delayMs);
    }
  }

  throw new Error("VS Code download retry loop exited unexpectedly.");
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
    const downloadedExecutablePath = await downloadVSCodeWithRetry({
      version: vscodeVersion,
      timeout: resolveVSCodeDownloadTimeout()
    });
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
