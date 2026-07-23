#!/usr/bin/env node
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { verifyInstalledCandidate } from "./run-p08-mercury-media-session.mjs";

const ROOT = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const DESKTOP = "/usr/bin/openburnbar-linux-desktop";
const DAEMON_LAUNCHER = "/usr/libexec/openburnbar-daemon-launch";
const CONTROL = path.join(ROOT, "scripts/linux-port/p18-atspi-control.py");

function assert(value, message) {
  if (!value) throw new Error(message);
}
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
function writeExclusive(file, value) {
  const descriptor = fs.openSync(
    file,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
    0o600,
  );
  try {
    fs.writeFileSync(descriptor, value);
    fs.fsyncSync(descriptor);
  } finally {
    fs.closeSync(descriptor);
  }
}
function writeJson(file, value) {
  writeExclusive(file, Buffer.from(`${JSON.stringify(value, null, 2)}\n`));
}
function ownerOnlyDirectory(directory, label, { empty = false } = {}) {
  const supplied = path.resolve(directory);
  fs.mkdirSync(supplied, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(supplied);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    `${label} must be an owner-only real directory`,
  );
  const resolved = fs.realpathSync(supplied);
  if (empty)
    assert(fs.readdirSync(resolved).length === 0, `${label} must be empty`);
  return resolved;
}
function token(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    assert(
      stat.isFile() &&
        stat.uid === process.getuid?.() &&
        (stat.mode & 0o077) === 0,
      "P-18 daemon token must be an owner-only regular file",
    );
    const value = fs.readFileSync(fd, "utf8").trim();
    assert(
      value.length >= 32 && !/[\r\n]/u.test(value),
      "P-18 daemon token is invalid",
    );
    return value;
  } finally {
    fs.closeSync(fd);
  }
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
function installedDesktopPids(runner) {
  const result = runner.run("pgrep", [
    "-f",
    "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)",
  ]);
  if (result.status === 1) return [];
  assert(
    result.status === 0,
    `P-18 desktop preflight failed: ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter(Number.isSafeInteger);
}
async function waitFor(label, operation, timeoutMs = 20_000) {
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
  return (method, params) =>
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
      socket.setTimeout(10_000, () =>
        finish(reject, new Error(`P-18 RPC timed out: ${method}`)),
      );
      socket.on("error", (error) => finish(reject, error));
      socket.on("connect", () =>
        socket.write(
          `${JSON.stringify({
            protocolVersion: 1,
            id: `p18-${++sequence}`,
            method,
            traceId: `p18-trace-${sequence}`,
            authToken,
            params,
          })}\n`,
        ),
      );
      socket.on("data", (chunk) => {
        buffer += chunk;
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        try {
          const document = JSON.parse(buffer.slice(0, newline));
          if (document.error)
            finish(
              reject,
              new Error(document.error.message ?? `P-18 RPC failed: ${method}`),
            );
          else finish(resolve, document.result);
        } catch (error) {
          finish(reject, error);
        }
      });
    });
}
function daemonController(runner, options) {
  let child = null;
  let wasActive = false;
  const env = environment(options);
  const stopChild = async () => {
    if (!child) return;
    child.kill();
    await waitFor(`P-18 daemon PID ${child.pid} exit`, () => {
      const result = runner.run("kill", ["-0", String(child.pid)]);
      assert(result.status !== 0, "daemon is still running");
      return true;
    });
    child = null;
  };
  const launch = async (label) => {
    fs.rmSync(options.socketPath, { force: true });
    const log = fs.openSync(
      path.join(options.rawOutputDir, `daemon-${label}.log`),
      "wx",
      0o600,
    );
    const process = spawn(
      DAEMON_LAUNCHER,
      ["--version", `p18-installed-${label}`],
      { env, stdio: ["ignore", log, log] },
    );
    process.unref();
    fs.closeSync(log);
    child = process;
    await waitFor(`P-18 daemon ${label}`, () => {
      assert(
        fs.existsSync(options.socketPath) &&
          fs.lstatSync(options.socketPath).isSocket(),
        "daemon socket is absent",
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
      wasActive = status.status === 0;
      assert(
        [0, 3].includes(status.status),
        "P-18 could not determine the user daemon state",
      );
      if (wasActive)
        required(
          runner,
          "systemctl",
          ["--user", "stop", "openburnbar-daemon.service"],
          "stop user daemon",
        );
      await launch("initial");
    },
    async restart() {
      await stopChild();
      await launch("restart");
    },
    async restore() {
      await stopChild();
      if (wasActive)
        required(
          runner,
          "systemctl",
          ["--user", "start", "openburnbar-daemon.service"],
          "restore user daemon",
        );
    },
  };
}
function atspi(runner, output, suffix, mode, name = null) {
  const file = path.join(output, `.p18-atspi-${suffix}.json`);
  const args = [CONTROL, "--mode", mode, "--output", file];
  if (name) args.push("--name", name);
  required(runner, "python3", args, `P-18 AT-SPI ${suffix}`);
  const document = JSON.parse(fs.readFileSync(file, "utf8"));
  fs.rmSync(file);
  return document;
}
function names(tree) {
  return (tree.nodes ?? [])
    .map((node) => String(node.name ?? ""))
    .filter(Boolean);
}
function includes(tree, text) {
  return names(tree).some((name) => name.includes(text));
}
function defaultUI(runner, options) {
  let app = null;
  return {
    async launch() {
      app = runner.start(DESKTOP, [], { env: environment(options) });
      assert(
        Number.isSafeInteger(app.pid) && app.pid > 1,
        "P-18 desktop returned no PID",
      );
      await waitFor("P-18 installed desktop window", () => {
        const result = runner.run("xdotool", [
          "search",
          "--onlyvisible",
          "--pid",
          String(app.pid),
          "--name",
          "^OpenBurnBar",
        ]);
        assert(
          result.status === 0 &&
            result.stdout.trim().split(/\s+/u).filter(Boolean).length === 1,
          "installed window is absent",
        );
        return true;
      });
      atspi(
        runner,
        options.rawOutputDir,
        "palette",
        "activate",
        "Open command palette",
      );
      atspi(runner, options.rawOutputDir, "route", "activate", "Memory");
      await sleep(600);
      atspi(runner, options.rawOutputDir, "all-filter", "activate", "All");
      await sleep(300);
      return { pid: app.pid };
    },
    snapshot(label) {
      return atspi(runner, options.rawOutputDir, label, "snapshot");
    },
    screenshot(name) {
      const file = path.join(options.rawOutputDir, name);
      required(
        runner,
        "scrot",
        ["--overwrite", "--focused", file],
        `P-18 ${name}`,
      );
      assert(fs.statSync(file).size > 1024, `P-18 ${name} is empty`);
      return file;
    },
    async stop() {
      if (!app) return;
      const pid = app.pid;
      app.kill();
      await waitFor(`P-18 desktop PID ${pid} exit`, () => {
        const result = runner.run("kill", ["-0", String(pid)]);
        assert(result.status !== 0, "desktop is still running");
        return true;
      });
      app = null;
    },
  };
}
function now(clock) {
  const value = Math.max(Date.now(), clock.value + 1);
  clock.value = value;
  return new Date(value).toISOString();
}

export async function runP18NativeMemoryProbes(options, dependencies = {}) {
  assert(
    (dependencies.platform ?? process.platform) === "linux",
    "P-18 native probe must execute on Linux",
  );
  assert(
    dependencies.desktopSession ??
      (process.env.DBUS_SESSION_BUS_ADDRESS && process.env.DISPLAY),
    "P-18 requires a live Linux X11 desktop and D-Bus session",
  );
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  options.rawOutputDir = ownerOnlyDirectory(
    options.rawOutputDir,
    "P-18 raw output",
    { empty: true },
  );
  options.supportDir = ownerOnlyDirectory(
    options.supportDir,
    "P-18 support directory",
  );
  options.homeDir = ownerOnlyDirectory(options.homeDir, "P-18 isolated home", {
    empty: true,
  });
  const authToken = token(options.tokenFile);
  assert(
    path.dirname(fs.realpathSync(options.tokenFile)) === options.supportDir,
    "P-18 token must be inside support directory",
  );
  assert(
    JSON.stringify(fs.readdirSync(options.supportDir).sort()) ===
      JSON.stringify([path.basename(options.tokenFile)]),
    "P-18 support directory must contain only its token",
  );
  assert(
    path.dirname(path.resolve(options.indexDatabase)) === options.supportDir &&
      !fs.existsSync(options.indexDatabase),
    "P-18 index database must be a missing support-directory child",
  );
  const runner = dependencies.runner ?? commandRunner();
  const processIDs = (
    dependencies.desktopProcessIDs ?? (() => installedDesktopPids(runner))
  )();
  assert(
    Array.isArray(processIDs) && processIDs.length === 0,
    "P-18 requires no pre-existing installed desktop process",
  );
  if (!dependencies.ui)
    for (const command of ["python3", "xdotool", "scrot"])
      required(
        runner,
        "sh",
        ["-c", 'command -v "$1" >/dev/null', "p18-tool", command],
        `required tool ${command}`,
      );
  const marker =
    dependencies.marker ?? `P18-${crypto.randomBytes(8).toString("hex")}`;
  const body = `Durable approved preference ${marker}`;
  const rejectedBody = `Rejected candidate ${marker}`;
  const daemon = dependencies.daemon ?? daemonController(runner, options);
  const rpc = dependencies.rpc ?? rpcClient(options, authToken);
  const ui = dependencies.ui ?? defaultUI(runner, options);
  const events = [];
  const uiEvents = [];
  const clock = { value: 0 };
  let app = null;
  let prepared = false;
  let memoryID;
  let rejectedMemoryID;
  let projectID;
  const call = async (phase, method, request) => {
    try {
      const result = await rpc(method, request);
      events.push({
        phase,
        at: now(clock),
        method,
        request,
        ok: true,
        error: null,
        result,
      });
      return result;
    } catch (error) {
      events.push({
        phase,
        at: now(clock),
        method,
        request,
        ok: false,
        error: error.message,
        result: null,
      });
      throw error;
    }
  };
  const launchAndSnapshot = async (phase, observed) => {
    app = await ui.launch();
    const tree = ui.snapshot(phase);
    const event = {
      phase,
      at: now(clock),
      appPid: app.pid,
      marker,
      memoryID,
      manifestSha256: options.manifestSha256,
      observed: observed(tree),
    };
    uiEvents.push(event);
    return tree;
  };
  try {
    await daemon.prepare();
    prepared = true;
    const created = await call("quarantine-created", "daemon.memory.remember", {
      text: body,
      projectPath: null,
      kind: "preference",
      scope: "personal",
      tags: ["p18-proof"],
      confidence: 0.97,
      sourcePath: null,
      reviewStatus: "quarantined",
    });
    ({ memoryID, projectID } = created);
    await call("normal-recall-excludes-quarantine", "daemon.memory.recall", {
      query: marker,
      projectPath: null,
      limit: 50,
      scope: "all",
      includeCrossProject: false,
      includeQuarantined: false,
      includeForgotten: false,
    });
    await call("review-feed-includes-quarantine", "daemon.memory.recall", {
      query: marker,
      projectPath: null,
      limit: 50,
      scope: "all",
      includeCrossProject: false,
      includeQuarantined: true,
      includeForgotten: true,
    });
    const pending = await launchAndSnapshot("pending", (tree) => ({
      body: includes(tree, body),
      approveAction: includes(tree, "Save as memory"),
      rejectAction: includes(tree, "Reject"),
      auditVisible: includes(tree, "Audit trail"),
    }));
    assert(
      includes(pending, body),
      "P-18 pending body is absent from the installed UI",
    );
    ui.screenshot("memory-initial.png");
    await ui.stop();
    app = null;

    await call("approved", "daemon.memory.review_status", {
      memoryID,
      projectPath: null,
      status: "approved",
    });
    await call("normal-recall-includes-approved", "daemon.memory.recall", {
      query: marker,
      projectPath: null,
      limit: 50,
      scope: "all",
      includeCrossProject: false,
      includeQuarantined: false,
      includeForgotten: false,
    });
    await launchAndSnapshot("approved", (tree) => ({
      status: includes(tree, "Approved"),
      forgetAction: includes(tree, "Forget permanently"),
    }));
    await ui.stop();
    app = null;

    const rejectedCreated = await call(
      "rejected-candidate-created",
      "daemon.memory.remember",
      {
        text: rejectedBody,
        projectPath: null,
        kind: "note",
        scope: "personal",
        tags: ["p18-proof"],
        confidence: 0.93,
        sourcePath: null,
        reviewStatus: "quarantined",
      },
    );
    rejectedMemoryID = rejectedCreated.memoryID;
    await call("rejected", "daemon.memory.review_status", {
      memoryID: rejectedMemoryID,
      projectPath: null,
      status: "rejected",
    });
    await call("normal-recall-excludes-rejected", "daemon.memory.recall", {
      query: marker,
      projectPath: null,
      limit: 50,
      scope: "all",
      includeCrossProject: false,
      includeQuarantined: false,
      includeForgotten: false,
    });
    await call("forgotten", "daemon.memory.forget", {
      memoryID,
      projectPath: null,
      requireCloudDelete: false,
    });
    await call("forgotten-tombstone", "daemon.memory.recall", {
      query: marker,
      projectPath: null,
      limit: 50,
      scope: "all",
      includeCrossProject: false,
      includeQuarantined: true,
      includeForgotten: true,
    });
    await launchAndSnapshot("rejected-forgotten", (tree) => ({
      rejectedStatus: includes(tree, "Rejected"),
      forgottenStatus: includes(tree, "Forgotten"),
      forgottenBodyAbsent: !includes(tree, body),
    }));
    await ui.stop();
    app = null;

    await daemon.restart();
    await call("restart-readback", "daemon.memory.recall", {
      query: marker,
      projectPath: null,
      limit: 50,
      scope: "all",
      includeCrossProject: false,
      includeQuarantined: true,
      includeForgotten: true,
    });
    await call("audit-readback", "daemon.memory.audit_trail", {
      projectPath: null,
      limit: 50,
    });
    await launchAndSnapshot("restart", (tree) => ({
      rejectedStatus: includes(tree, "Rejected"),
      forgottenStatus: includes(tree, "Forgotten"),
      auditVisible: includes(tree, "Audit trail"),
    }));
    ui.screenshot("memory-restart.png");
    writeJson(path.join(options.rawOutputDir, "memory-marker.json"), {
      marker,
      memoryID,
      rejectedMemoryID,
      projectID,
      body,
      rejectedBody,
    });
    writeJson(
      path.join(options.rawOutputDir, "memory-daemon-transcript.json"),
      {
        producer: "openburnbar-p18-installed-daemon-probe-v1",
        transport: "installed daemon AF_UNIX RPC",
        events,
      },
    );
    writeJson(path.join(options.rawOutputDir, "memory-ui-transcript.json"), {
      producer: "openburnbar-p18-installed-ui-probe-v1",
      events: uiEvents,
    });
    return { output: options.rawOutputDir, marker, memoryID, rejectedMemoryID };
  } finally {
    try {
      if (app) await ui.stop();
    } catch {
      /* preserve primary failure */
    }
    if (prepared) await daemon.restore();
  }
}

export function parseP18Arguments(argv) {
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
    if (
      !flags.includes(argv[index]) ||
      values.has(argv[index]) ||
      argv[index + 1] === undefined
    )
      throw new Error(`invalid argument: ${argv[index] ?? "<missing>"}`);
    values.set(argv[index], argv[index + 1]);
  }
  for (const flag of flags)
    if (!values.has(flag)) throw new Error(`${flag} is required`);
  return {
    rawOutputDir: values.get("--raw-output-dir"),
    supportDir: values.get("--support-dir"),
    homeDir: values.get("--home-dir"),
    socketPath: values.get("--socket-path"),
    tokenFile: values.get("--token-file"),
    indexDatabase: values.get("--index-database"),
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

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    process.stdout.write(
      `${JSON.stringify(await runP18NativeMemoryProbes(parseP18Arguments(process.argv.slice(2))), null, 2)}\n`,
    );
  } catch (error) {
    process.stderr.write(`P-18 native memory probe failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
