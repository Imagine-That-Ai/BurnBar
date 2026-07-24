#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";
import { runP24NativeSettingsProbes } from "./run-p24-native-settings-probes.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const DESKTOP = "/usr/bin/openburnbar-linux-desktop";
const DAEMON_LAUNCHER = "/usr/libexec/openburnbar-daemon-launch";
const PACKAGED_AUTOSTART = "/etc/xdg/autostart/openburnbar.desktop";
const CONTROL = path.join(ROOT, "scripts/linux-port/p24-atspi-control.py");
const SETTINGS_FIELDS = Object.freeze([
  "telemetryEnabled",
  "privacyOptIn",
  "cloudSyncEnabled",
]);

function assert(value, message) {
  if (!value) throw new Error(message);
}
function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
function commandRunner() {
  return {
    run(command, args = [], options = {}) {
      const result = spawnSync(command, args, {
        encoding: "utf8",
        timeout: 30_000,
        maxBuffer: 8 * 1024 * 1024,
        ...options,
      });
      if (result.error) throw result.error;
      return {
        status: result.status,
        stdout: result.stdout ?? "",
        stderr: result.stderr ?? "",
      };
    },
    start(command, args = [], options = {}) {
      const child = spawn(command, args, {
        stdio: ["ignore", "ignore", "ignore"],
        ...options,
      });
      child.unref();
      return {
        pid: child.pid,
        kill: (signal = "SIGTERM") => child.kill(signal),
      };
    },
  };
}
function required(runner, command, args, label, options = {}) {
  const result = runner.run(command, args, options);
  assert(
    result.status === 0,
    `${label} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout.trim();
}
async function waitFor(label, operation, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      return await operation();
    } catch (error) {
      lastError = error;
      await sleep(250);
    }
  }
  throw new Error(`${label} timed out: ${lastError?.message ?? "unavailable"}`);
}
function ownerOnlyDirectory(directory, label, { empty = false } = {}) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    `${label} must be an owner-only real directory`,
  );
  if (empty)
    assert(fs.readdirSync(directory).length === 0, `${label} must be empty`);
  return fs.realpathSync(directory);
}
function readToken(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW, 0o600);
  try {
    const stat = fs.fstatSync(fd);
    assert(
      stat.isFile() &&
        stat.uid === process.getuid?.() &&
        (stat.mode & 0o077) === 0,
      "P-24 daemon token must be owner-only",
    );
    const token = fs.readFileSync(fd, "utf8").trim();
    assert(
      token.length >= 32 && !/[\r\n]/u.test(token),
      "P-24 daemon token is invalid",
    );
    return token;
  } finally {
    fs.closeSync(fd);
  }
}
function environment(options) {
  return {
    ...process.env,
    HOME: options.homeDir,
    XDG_CONFIG_HOME: path.join(options.homeDir, ".config"),
    XDG_DATA_HOME: path.join(options.homeDir, ".local/share"),
    OPENBURNBAR_DAEMON_SUPPORT_DIR: options.supportDir,
    OPENBURNBAR_DAEMON_SOCKET_PATH: options.socketPath,
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE: options.tokenFile,
    OPENBURNBAR_INDEX_DATABASE_PATH: options.indexDatabase,
  };
}
function rpcClient(options, authToken) {
  let sequence = 0;
  return (method, params = {}) =>
    new Promise((resolve, reject) => {
      const socket = net.createConnection(options.socketPath);
      let buffer = "";
      let settled = false;
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        socket.destroy();
        callback(value);
      };
      socket.setEncoding("utf8");
      socket.setTimeout(15_000, () =>
        finish(reject, new Error(`P-24 RPC timed out: ${method}`)),
      );
      socket.on("error", (error) => finish(reject, error));
      socket.on("connect", () => {
        sequence += 1;
        socket.write(
          `${JSON.stringify({
            protocolVersion: 1,
            id: `p24-${sequence}`,
            method,
            traceId: `p24-trace-${sequence}`,
            authToken,
            params,
          })}\n`,
        );
      });
      socket.on("data", (chunk) => {
        buffer += chunk;
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        try {
          const document = JSON.parse(buffer.slice(0, newline));
          if (document.error)
            finish(
              reject,
              new Error(document.error.message ?? `P-24 RPC failed: ${method}`),
            );
          else finish(resolve, document.result);
        } catch (error) {
          finish(reject, error);
        }
      });
    });
}
function desktopProcessIDs(runner) {
  const result = runner.run("pgrep", [
    "-f",
    "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)",
  ]);
  if (result.status === 1) return [];
  assert(result.status === 0, "P-24 could not inspect desktop processes");
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter(Number.isSafeInteger);
}
function daemonController(runner, options) {
  const env = environment(options);
  let child = null;
  let wasActive = false;
  let launches = 0;
  const stop = async () => {
    if (!child) return;
    const pid = child.pid;
    child.kill();
    await waitFor(`P-24 daemon PID ${pid} exit`, () => {
      assert(
        runner.run("kill", ["-0", String(pid)]).status !== 0,
        "daemon alive",
      );
      return true;
    });
    child = null;
    fs.rmSync(options.socketPath, { force: true });
  };
  const start = async () => {
    assert(!child, "P-24 isolated daemon is already running");
    fs.rmSync(options.socketPath, { force: true });
    launches += 1;
    const log = fs.openSync(
      path.join(options.supportDir, `p24-daemon-${launches}.log`),
      "wx",
      0o600,
    );
    const process = spawn(
      DAEMON_LAUNCHER,
      ["--version", `p24-installed-${launches}`],
      { env, stdio: ["ignore", log, log] },
    );
    process.unref();
    fs.closeSync(log);
    child = process;
    await waitFor("P-24 isolated daemon", () => {
      assert(
        fs.existsSync(options.socketPath) &&
          fs.lstatSync(options.socketPath).isSocket(),
        "daemon socket absent",
      );
      return true;
    });
  };
  return {
    async prepare() {
      const status = runner.run("systemctl", [
        "--user",
        "is-active",
        "--quiet",
        "openburnbar-daemon.service",
      ]);
      assert([0, 3].includes(status.status), "P-24 cannot inspect user daemon");
      wasActive = status.status === 0;
      if (wasActive)
        required(
          runner,
          "systemctl",
          ["--user", "stop", "openburnbar-daemon.service"],
          "stop installed user daemon",
        );
      try {
        await start();
      } catch (error) {
        await this.restore();
        throw error;
      }
    },
    async restart() {
      await stop();
      await start();
    },
    stop,
    start,
    async restore() {
      await stop();
      if (wasActive)
        required(
          runner,
          "systemctl",
          ["--user", "start", "openburnbar-daemon.service"],
          "restore installed user daemon",
        );
    },
  };
}
function atspi(runner, options, suffix, mode, name = null, value = null) {
  const file = path.join(options.rawOutputDir, `.p24-atspi-${suffix}.json`);
  const args = [CONTROL, "--mode", mode, "--output", file];
  if (name) args.push("--name", name);
  if (value !== null) args.push("--value", value);
  required(runner, "python3", args, `P-24 AT-SPI ${suffix}`);
  const result = JSON.parse(fs.readFileSync(file, "utf8"));
  fs.rmSync(file);
  return result;
}
function screenshot(runner, options, name) {
  const file = path.join(options.rawOutputDir, name);
  required(runner, "scrot", ["--overwrite", "--focused", file], `P-24 ${name}`);
  assert(fs.statSync(file).size >= 1024, `P-24 ${name} is empty`);
  return file;
}
function focusedActionable(tree) {
  return (tree.nodes ?? []).find(
    (node) => node.states?.includes("focused") && node.actions?.length > 0,
  );
}
function uiAdapter(runner, options) {
  let app = null;
  return {
    async launch(uri) {
      app = runner.start(DESKTOP, [uri], { env: environment(options) });
      assert(
        Number.isSafeInteger(app.pid) && app.pid > 1,
        "P-24 desktop returned no PID",
      );
      await waitFor("P-24 installed desktop window", () => {
        const result = runner.run("xdotool", [
          "search",
          "--onlyvisible",
          "--pid",
          String(app.pid),
          "--name",
          "^OpenBurnBar",
        ]);
        assert(result.status === 0, "installed Settings window absent");
        return true;
      });
      await sleep(800);
    },
    async auditTab({ tabId, title }) {
      const tree = atspi(
        runner,
        options,
        `tab-${tabId}`,
        "audit-tab",
        "Search settings",
        title,
      );
      return {
        tree,
        selectedName: tree.activation?.name,
        focusedName: title,
        action: tree.activation?.action,
        daemonMethod: "daemon.config.update",
        screenshot: screenshot(runner, options, `settings-${tabId}.png`),
      };
    },
    async captureRecovery(state) {
      await sleep(800);
      let tree = atspi(runner, options, `recovery-${state}`, "snapshot");
      const expected =
        state === "degraded"
          ? /did not respond|retry|unavailable/iu
          : /connected|settings|healthy/iu;
      let node = focusedActionable(tree);
      if (!node || !expected.test(node.name ?? "")) {
        const candidate = (tree.nodes ?? []).find(
          (value) =>
            expected.test(value.name ?? "") && value.actions?.length > 0,
        );
        assert(
          candidate,
          `P-24 ${state} exposed no truthful actionable recovery node`,
        );
        atspi(
          runner,
          options,
          `recovery-${state}-focus`,
          "activate",
          candidate.name,
        );
        tree = atspi(runner, options, `recovery-${state}-focused`, "snapshot");
        node = (tree.nodes ?? []).find(
          (value) =>
            value.name === candidate.name &&
            value.states?.includes("focused") &&
            value.actions?.length > 0,
        );
      }
      assert(node?.name, `P-24 ${state} exposed no focused recovery node`);
      return {
        tree,
        focusedName: node.name,
        screenshot: screenshot(runner, options, `settings-${state}.png`),
      };
    },
    async stop() {
      if (!app) return;
      const pid = app.pid;
      app.kill();
      await waitFor(`P-24 desktop PID ${pid} exit`, () => {
        assert(
          runner.run("kill", ["-0", String(pid)]).status !== 0,
          "desktop alive",
        );
        return true;
      });
      app = null;
    },
  };
}
function configSnapshot(result) {
  const snapshot = result?.snapshot ?? result;
  assert(
    snapshot && typeof snapshot === "object" && !Array.isArray(snapshot),
    "P-24 config snapshot missing",
  );
  return snapshot;
}
function settingsAdapter(rpc) {
  const fields = new Set(SETTINGS_FIELDS);
  const field = (name) => {
    assert(fields.has(name), `P-24 unknown Settings field: ${name}`);
    return name;
  };
  return {
    async readField(name) {
      const selected = field(name);
      const snapshot = configSnapshot(await rpc("daemon.config.get", {}));
      assert(
        typeof snapshot[selected] === "boolean",
        `P-24 ${selected} is not writable`,
      );
      return { field: selected, value: snapshot[selected] };
    },
    async writeField(name, value) {
      const selected = field(name);
      assert(typeof value === "boolean", `P-24 ${selected} value is invalid`);
      const snapshot = configSnapshot(await rpc("daemon.config.get", {}));
      snapshot[selected] = value;
      const written = configSnapshot(
        await rpc("daemon.config.update", { snapshot }),
      );
      return { field: selected, value: written[selected] };
    },
    async restoreField(name, before) {
      const selected = field(name);
      assert(
        before.field === selected && typeof before.value === "boolean",
        `P-24 ${selected} restore receipt invalid`,
      );
      const snapshot = configSnapshot(await rpc("daemon.config.get", {}));
      snapshot[selected] = before.value;
      await rpc("daemon.config.update", { snapshot });
    },
  };
}
function parseDesktopEnabled(bytes) {
  if (!bytes) return true;
  const hidden = /^Hidden\s*=\s*(true|false)\s*$/imu.exec(
    bytes.toString("utf8"),
  );
  return hidden?.[1].toLowerCase() !== "true";
}
function writeAutostart(file, template, enabled) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  if (fs.existsSync(file))
    assert(
      !fs.lstatSync(file).isSymbolicLink(),
      "P-24 autostart override is a symlink",
    );
  let value = template
    .toString("utf8")
    .replace(/^Hidden\s*=.*$/gimu, "")
    .trimEnd();
  value = `${value}\nHidden=${enabled ? "false" : "true"}\n`;
  const temporary = `${file}.tmp-${process.pid}-${crypto.randomUUID()}`;
  fs.writeFileSync(temporary, value, { flag: "wx", mode: 0o600 });
  fs.renameSync(temporary, file);
}
function fileBackup(file) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW, 0o600);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
  try {
    const stat = fs.fstatSync(fd);
    assert(stat.isFile(), `P-24 unsafe file: ${file}`);
    return {
      bytes: fs.readFileSync(fd),
      mode: stat.mode & 0o777,
      atime: stat.atime,
      mtime: stat.mtime,
    };
  } finally {
    fs.closeSync(fd);
  }
}
function restoreFile(file, backup) {
  fs.rmSync(file, { force: true });
  if (!backup) return;
  fs.writeFileSync(file, backup.bytes, { flag: "wx", mode: backup.mode });
  fs.utimesSync(file, backup.atime, backup.mtime);
}
function nativeAdapter(options) {
  const autostart = path.join(
    options.homeDir,
    ".config/autostart/openburnbar.desktop",
  );
  const packaged = fs.readFileSync(PACKAGED_AUTOSTART);
  const originalAutostart = fileBackup(autostart);
  return {
    async launchAtLoginStatus() {
      const user = fileBackup(autostart);
      return {
        enabled: parseDesktopEnabled(user?.bytes ?? packaged),
        path: autostart,
        source: user ? "user" : "packaged",
        userOverride: Boolean(user),
      };
    },
    async launchAtLoginSet(enabled) {
      writeAutostart(autostart, originalAutostart?.bytes ?? packaged, enabled);
      return this.launchAtLoginStatus();
    },
    async restoreLaunchAtLogin() {
      restoreFile(autostart, originalAutostart);
      return this.launchAtLoginStatus();
    },
    restoreAutostart() {
      restoreFile(autostart, originalAutostart);
    },
  };
}

export async function createP24InstalledWorkflow(options, injected = {}) {
  const platform = injected.platform ?? process.platform;
  assert(platform === "linux", "P-24 installed workflow requires Linux");
  assert(
    injected.desktopSession ??
      Boolean(
        process.env.DBUS_SESSION_BUS_ADDRESS &&
        (process.env.DISPLAY || process.env.WAYLAND_DISPLAY),
      ),
    "P-24 installed workflow requires a live desktop and D-Bus session",
  );
  (injected.installedVerifier ?? verifyInstalledCandidate)(options);
  options.supportDir = ownerOnlyDirectory(
    options.supportDir,
    "P-24 support directory",
  );
  options.homeDir = ownerOnlyDirectory(options.homeDir, "P-24 isolated home", {
    empty: true,
  });
  assert(
    path.dirname(fs.realpathSync(options.tokenFile)) === options.supportDir,
    "P-24 token must be in support directory",
  );
  assert(
    JSON.stringify(fs.readdirSync(options.supportDir).sort()) ===
      JSON.stringify([path.basename(options.tokenFile)]),
    "P-24 support directory must initially contain only its token",
  );
  assert(
    path.dirname(path.resolve(options.socketPath)) === options.supportDir &&
      !fs.existsSync(options.socketPath),
    "P-24 socket must be a missing support-directory child",
  );
  assert(
    path.dirname(path.resolve(options.indexDatabase)) === options.supportDir &&
      !fs.existsSync(options.indexDatabase),
    "P-24 index must be a missing support-directory child",
  );
  const token = readToken(options.tokenFile);
  const runner = injected.runner ?? commandRunner();
  for (const command of ["python3", "xdotool", "scrot"])
    required(
      runner,
      "sh",
      ["-c", 'command -v "$1" >/dev/null', "p24-tool", command],
      `required tool ${command}`,
    );
  const daemon = injected.daemon ?? daemonController(runner, options);
  await daemon.prepare();
  let rpc;
  let settings;
  let native;
  let ui;
  try {
    rpc = injected.rpc ?? rpcClient(options, token);
    settings = settingsAdapter(rpc);
    native = nativeAdapter(options);
    ui = injected.ui ?? uiAdapter(runner, options);
  } catch (error) {
    try {
      await daemon.restore();
    } catch (restoreError) {
      throw new AggregateError(
        [error, restoreError],
        `P-24 CRITICAL setup restoration failed: ${restoreError.message}`,
      );
    }
    throw error;
  }
  let restored = false;
  return {
    dependencies: {
      platform,
      desktopSession: true,
      installedVerifier() {},
      desktopProcessIDs:
        injected.desktopProcessIDs ?? (() => desktopProcessIDs(runner)),
      settings,
      daemon,
      native,
      ui,
    },
    async restore() {
      if (restored) return;
      restored = true;
      let primary;
      try {
        await ui.stop();
      } catch (error) {
        primary = error;
      }
      try {
        native.restoreAutostart();
        await daemon.restore();
      } catch (error) {
        primary ??= error;
      }
      if (primary) throw primary;
    },
  };
}

export function parseP24InstalledArguments(argv) {
  const flags = [
    "--raw-output-dir",
    "--support-dir",
    "--home-dir",
    "--socket-path",
    "--token-file",
    "--index-database",
    "--environment",
    "--target-head",
    "--candidate-run-id",
    "--candidate-artifact-digest",
    "--package-version",
    "--manifest-sha256",
    "--manifest-signature-sha256",
    "--compositor",
  ];
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (
      !flags.includes(flag) ||
      values.has(flag) ||
      value === undefined ||
      value.startsWith("--")
    )
      throw new Error(`invalid argument: ${flag ?? "<missing>"}`);
    values.set(flag, value);
  }
  for (const flag of flags)
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    rawOutputDir: path.resolve(values.get("--raw-output-dir")),
    supportDir: path.resolve(values.get("--support-dir")),
    homeDir: path.resolve(values.get("--home-dir")),
    socketPath: path.resolve(values.get("--socket-path")),
    tokenFile: path.resolve(values.get("--token-file")),
    indexDatabase: path.resolve(values.get("--index-database")),
    environmentId: values.get("--environment"),
    targetHead: values.get("--target-head"),
    candidateRunId: values.get("--candidate-run-id"),
    candidateArtifactDigest: values.get("--candidate-artifact-digest"),
    packageVersion: values.get("--package-version"),
    manifestSha256: values.get("--manifest-sha256"),
    manifestSignatureSha256: values.get("--manifest-signature-sha256"),
    compositor: values.get("--compositor"),
  };
}

export async function runP24InstalledSettingsWorkflow(argv, injected = {}) {
  const options = parseP24InstalledArguments(argv);
  const workflow = await (
    injected.createWorkflow ?? createP24InstalledWorkflow
  )(options, injected);
  let primary;
  let result;
  try {
    result = await (injected.runProbe ?? runP24NativeSettingsProbes)(
      options,
      workflow.dependencies,
    );
  } catch (error) {
    primary = error;
  }
  try {
    await workflow.restore();
  } catch (restoreError) {
    throw new AggregateError(
      primary ? [primary, restoreError] : [restoreError],
      `P-24 CRITICAL workflow restoration failed: ${restoreError.message}`,
    );
  }
  if (primary) throw primary;
  return result;
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  runP24InstalledSettingsWorkflow(process.argv.slice(2))
    .then((result) => process.stdout.write(`${JSON.stringify(result)}\n`))
    .catch((error) => {
      process.stderr.write(`${error.stack ?? error.message}\n`);
      process.exitCode = 1;
    });
}
