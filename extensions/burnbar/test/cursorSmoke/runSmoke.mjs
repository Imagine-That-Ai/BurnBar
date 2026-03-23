import { mkdtempSync, cpSync, mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { execFileSync, spawn } from "node:child_process";

const repoRoot = join(dirname(dirname(dirname(new URL(import.meta.url).pathname))), "..", "..");
const extensionRoot = join(repoRoot, "extensions", "burnbar");
const daemonBinary = join(
  execFileSync("swift", ["build", "--package-path", join(repoRoot, "BurnBarDaemon"), "--show-bin-path"], {
    encoding: "utf8"
  }).trim(),
  "BurnBarDaemon"
);
const cursorBinary = "/Applications/Cursor.app/Contents/MacOS/Cursor";

const tempRoot = mkdtempSync(join(tmpdir(), "burnbar-cursor-smoke-"));
const userDataDir = join(tempRoot, "user-data");
const extensionsDir = join(tempRoot, "extensions");
const workspaceDir = join(tempRoot, "workspace");
const supportDir = join(tempRoot, "burnbar-support");
const smokeOutput = join(tempRoot, "smoke-output.json");
const socketPath = join(tempRoot, "burnbar-daemon.sock");
const logPath = join(tempRoot, "burnbar-daemon.log");

mkdirSync(userDataDir, { recursive: true });
mkdirSync(extensionsDir, { recursive: true });
mkdirSync(workspaceDir, { recursive: true });
mkdirSync(supportDir, { recursive: true });
mkdirSync(join(userDataDir, "User"), { recursive: true });
mkdirSync(join(workspaceDir, "src"), { recursive: true });

writeFileSync(join(workspaceDir, "src", "example.ts"), "export const value = 42;\n", "utf8");
writeFileSync(
  join(userDataDir, "User", "settings.json"),
  JSON.stringify(
    {
      "security.workspace.trust.enabled": false,
      "burnbar.cursorSmoke.outputPath": smokeOutput,
      "burnbar.cursorSmoke.filePath": join(workspaceDir, "src", "example.ts"),
      "burnbar.cursorSmoke.modelID": "glm-5"
    },
    null,
    2
  ),
  "utf8"
);
writeFileSync(
  join(supportDir, "provider-config.json"),
  JSON.stringify(
    {
      providers: [
        {
          providerID: "zai",
          isEnabled: true,
          baseURL: "https://api.z.ai/api/coding/paas/v4",
          preferredModelIDs: ["glm-5"]
        },
        {
          providerID: "minimax",
          isEnabled: false,
          baseURL: "https://api.minimax.io/v1",
          preferredModelIDs: ["minimax-m2.7-highspeed"]
        }
      ]
    },
    null,
    2
  ),
  "utf8"
);

const unpackedExtensionPath = join(extensionsDir, "burnbar.burnbar-0.0.1");
cpSync(extensionRoot, unpackedExtensionPath, {
  recursive: true,
  filter(src) {
    return !src.includes("/node_modules") && !src.includes("/.vscode-test") && !src.includes("/coverage");
  }
});

let previousSecret = null;
try {
  previousSecret = execFileSync("security", [
    "find-generic-password",
    "-s",
    "com.burnbar.cursor-connector",
    "-a",
    "provider.zai.apiKey",
    "-w"
  ], { encoding: "utf8" }).trim();
} catch {
  previousSecret = null;
}

execFileSync("security", [
  "add-generic-password",
  "-U",
  "-s",
  "com.burnbar.cursor-connector",
  "-a",
  "provider.zai.apiKey",
  "-w",
  "burnbar-smoke-secret"
]);

const daemon = spawn(daemonBinary, ["--socket-path", socketPath, "--version", "cursor-smoke"], {
  env: {
    ...process.env,
    BURNBAR_DAEMON_SUPPORT_DIR: supportDir
  },
  stdio: ["ignore", "ignore", "ignore"]
});

const daemonStart = Date.now();
while (!existsSync(socketPath)) {
  if (daemon.exitCode != null) {
    throw new Error(`BurnBar daemon exited before creating the socket (exit ${daemon.exitCode}).`);
  }
  if (Date.now() - daemonStart > 10000) {
    throw new Error("Timed out waiting for the BurnBar daemon socket to appear.");
  }
  await new Promise((resolve) => setTimeout(resolve, 100));
}

const cursor = spawn(cursorBinary, [workspaceDir, "--new-window", "--user-data-dir", userDataDir, "--extensions-dir", extensionsDir, "--disable-gpu"], {
  env: {
    ...process.env,
    BURNBAR_DAEMON_SOCKET_PATH: socketPath
  },
  stdio: ["ignore", "ignore", "ignore"]
});

const start = Date.now();
while (!existsSync(smokeOutput)) {
  if (Date.now() - start > 60000) {
    throw new Error("Timed out waiting for Cursor smoke output.");
  }
  await new Promise((resolve) => setTimeout(resolve, 250));
}

let result = JSON.parse(readFileSync(smokeOutput, "utf8"));
while (!result.ok && !result.error) {
  if (Date.now() - start > 120000) {
    throw new Error("Timed out waiting for Cursor smoke run completion.");
  }

  await new Promise((resolve) => setTimeout(resolve, 250));
  result = JSON.parse(readFileSync(smokeOutput, "utf8"));
}
cursor.kill("SIGTERM");
daemon.kill("SIGTERM");

if (previousSecret) {
  execFileSync("security", [
    "add-generic-password",
    "-U",
    "-s",
    "com.burnbar.cursor-connector",
    "-a",
    "provider.zai.apiKey",
    "-w",
    previousSecret
  ]);
} else {
  try {
    execFileSync("security", [
      "delete-generic-password",
      "-s",
      "com.burnbar.cursor-connector",
      "-a",
      "provider.zai.apiKey"
    ]);
  } catch {}
}

if (!result.ok) {
  throw new Error(result.error ?? `Unknown Cursor smoke failure (stage: ${result.stage ?? "unknown"}).`);
}

console.log(JSON.stringify(result));
