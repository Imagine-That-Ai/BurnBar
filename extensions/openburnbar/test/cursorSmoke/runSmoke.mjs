import { mkdtempSync, cpSync, mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { execFileSync, spawn } from "node:child_process";
import { createConnection } from "node:net";

const repoRoot = join(dirname(dirname(dirname(new URL(import.meta.url).pathname))), "..", "..");
const extensionRoot = join(repoRoot, "extensions", "openburnbar");
const daemonBinary = join(
  execFileSync("swift", ["build", "--package-path", join(repoRoot, "OpenBurnBarDaemon"), "--show-bin-path"], {
    encoding: "utf8"
  }).trim(),
  "OpenBurnBarDaemon"
);
const cursorBinary = "/Applications/Cursor.app/Contents/MacOS/Cursor";

const tempRoot = mkdtempSync(join(tmpdir(), "openburnbar-cursor-smoke-"));
const smokeID = tempRoot.slice(-6);
const userDataDir = join(tempRoot, "user-data");
const extensionsDir = join(tempRoot, "extensions");
const workspaceDir = join(tempRoot, "workspace");
const supportDir = join(tempRoot, "openburnbar-support");
const smokeOutput = join(tempRoot, "smoke-output.json");
const socketPath = join("/tmp", `obbcs-${smokeID}.sock`);
const logPath = join("/tmp", `obbcs-${smokeID}.log`);
const fakeProviderOutputsPath = join(tempRoot, "fake-provider-outputs.json");

mkdirSync(userDataDir, { recursive: true });
mkdirSync(extensionsDir, { recursive: true });
mkdirSync(workspaceDir, { recursive: true });
mkdirSync(supportDir, { recursive: true });
mkdirSync(join(userDataDir, "User"), { recursive: true });
mkdirSync(join(workspaceDir, "src"), { recursive: true });

writeFileSync(join(workspaceDir, "src", "example.ts"), "export const value = 42;\n", "utf8");
writeFileSync(
  fakeProviderOutputsPath,
  JSON.stringify({
    outputs: [
      JSON.stringify({
        action: "search_workspace",
        requestedTool: "search_workspace",
        arguments: {
          query: "value"
        },
        rationale: "Find the target file before editing."
      }),
      JSON.stringify({
        action: "read_file",
        requestedTool: "read_file",
        arguments: {
          path: join(workspaceDir, "src", "example.ts")
        },
        rationale: "Inspect the current file contents before patching."
      }),
      JSON.stringify({
        action: "apply_patch",
        requestedTool: "apply_patch",
        arguments: {
          changes: [
            {
              path: join(workspaceDir, "src", "example.ts"),
              text: "export const value = 43;\n"
            }
          ]
        },
        rationale: "Apply the requested constant update."
      }),
      JSON.stringify({
        action: "complete",
        rationale: "The file has been updated successfully.",
        message: "Done."
      })
    ]
  }, null, 2),
  "utf8"
);
writeFileSync(
  join(userDataDir, "User", "settings.json"),
  JSON.stringify(
    {
      "security.workspace.trust.enabled": false,
      "openburnbar.cursorSmoke.outputPath": smokeOutput,
      "openburnbar.cursorSmoke.filePath": join(workspaceDir, "src", "example.ts"),
      "openburnbar.cursorSmoke.modelID": "glm-5"
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

const unpackedExtensionPath = join(extensionsDir, "openburnbar.openburnbar-0.0.1");
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
    "com.openburnbar.cursor-connector",
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
  "com.openburnbar.cursor-connector",
  "-a",
  "provider.zai.apiKey",
  "-w",
  "openburnbar-smoke-secret"
]);

const daemon = spawn(daemonBinary, ["--socket-path", socketPath, "--version", "cursor-smoke"], {
  env: {
    ...process.env,
    OPENBURNBAR_DAEMON_SUPPORT_DIR: supportDir,
    BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE: fakeProviderOutputsPath
  },
  stdio: ["ignore", "ignore", "ignore"]
});

const daemonStart = Date.now();
while (!existsSync(socketPath)) {
  if (daemon.exitCode != null) {
    throw new Error(`OpenBurnBar daemon exited before creating the socket (exit ${daemon.exitCode}).`);
  }
  if (Date.now() - daemonStart > 10000) {
    throw new Error("Timed out waiting for the OpenBurnBar daemon socket to appear.");
  }
  await new Promise((resolve) => setTimeout(resolve, 100));
}

await waitForDaemonHealth(socketPath, daemon);

const cursor = spawn(cursorBinary, [workspaceDir, "--new-window", "--user-data-dir", userDataDir, "--extensions-dir", extensionsDir, "--disable-gpu"], {
  env: {
    ...process.env,
    OPENBURNBAR_DAEMON_SOCKET_PATH: socketPath
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
    "com.openburnbar.cursor-connector",
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
      "com.openburnbar.cursor-connector",
      "-a",
      "provider.zai.apiKey"
    ]);
  } catch {}
}

if (!result.ok) {
  throw new Error(result.error ?? `Unknown Cursor smoke failure (stage: ${result.stage ?? "unknown"}).`);
}

console.log(JSON.stringify(result));

async function waitForDaemonHealth(socketPath, daemonProcess, timeoutMs = 60000) {
  const startedAt = Date.now();
  let lastError = "Unknown daemon health error.";

  while (Date.now() - startedAt <= timeoutMs) {
    if (daemonProcess.exitCode != null) {
      throw new Error(`OpenBurnBar daemon exited before responding to health (exit ${daemonProcess.exitCode}).`);
    }

    try {
      await requestHealth(socketPath);
      return;
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }

  throw new Error(lastError);
}

async function requestHealth(socketPath) {
  const payload = `${JSON.stringify({ id: "smoke-health", method: "daemon.health" })}\n`;

  return await new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    let responseBuffer = "";
    let settled = false;

    const timeout = setTimeout(() => {
      socket.destroy();
      fail(new Error(`Timed out waiting for OpenBurnBar daemon on ${socketPath}.`));
    }, 3000);

    const cleanup = () => {
      clearTimeout(timeout);
      socket.removeAllListeners();
    };

    const fail = (error) => {
      if (settled) {
        return;
      }
      settled = true;
      cleanup();
      reject(error);
    };

    socket.setEncoding("utf8");

    socket.on("connect", () => {
      socket.write(payload);
    });

    socket.on("data", (chunk) => {
      responseBuffer += chunk;
      const newlineIndex = responseBuffer.indexOf("\n");
      if (newlineIndex === -1) {
        return;
      }

      const line = responseBuffer.slice(0, newlineIndex).trim();
      if (!line) {
        fail(new Error("OpenBurnBar daemon returned an empty response."));
        return;
      }

      try {
        const envelope = JSON.parse(line);
        if (envelope.error) {
          fail(new Error(envelope.error.message));
          return;
        }
        if (!envelope.result?.ok) {
          fail(new Error("OpenBurnBar daemon health response was not OK."));
          return;
        }
        settled = true;
        cleanup();
        resolve(envelope.result);
        socket.end();
      } catch (error) {
        fail(error instanceof Error ? error : new Error("Failed to parse OpenBurnBar daemon health response."));
      }
    });

    socket.on("error", (error) => {
      fail(new Error(`Timed out waiting for OpenBurnBar daemon on ${socketPath}.`));
    });

    socket.on("end", () => {
      if (!settled && responseBuffer.trim().length === 0) {
        fail(new Error("OpenBurnBar daemon closed the connection before replying."));
      }
    });
  });
}
