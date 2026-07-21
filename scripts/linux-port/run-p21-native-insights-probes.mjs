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
const CONTROL = path.join(ROOT, "scripts/linux-port/p21-atspi-control.py");
const APPLE_REFERENCE_SECONDS = 978_307_200;

function assert(value, message) {
  if (!value) throw new Error(message);
}
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
function writeExclusive(file, value) {
  const fd = fs.openSync(
    file,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
    0o600,
  );
  try {
    fs.writeFileSync(fd, value);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
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
function readToken(file) {
  const stat = fs.lstatSync(file);
  assert(
    stat.isFile() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    "P-21 daemon token must be an owner-only regular file",
  );
  const value = fs.readFileSync(file, "utf8").trim();
  assert(
    value.length >= 32 && !/[\r\n]/u.test(value),
    "P-21 daemon token is invalid",
  );
  return value;
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
    `P-21 desktop preflight failed: ${(result.stderr || result.stdout).trim()}`,
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
        if (!settled) {
          settled = true;
          socket.destroy();
          callback(value);
        }
      };
      socket.setEncoding("utf8");
      socket.setTimeout(10_000, () =>
        finish(reject, new Error(`P-21 RPC timed out: ${method}`)),
      );
      socket.on("error", (error) => finish(reject, error));
      socket.on("connect", () =>
        socket.write(
          `${JSON.stringify({
            protocolVersion: 1,
            id: `p21-${++sequence}`,
            method,
            traceId: `p21-trace-${sequence}`,
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
              new Error(document.error.message ?? `P-21 RPC failed: ${method}`),
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
    const pid = child.pid;
    child.kill();
    await waitFor(`P-21 daemon PID ${pid} exit`, () => {
      const result = runner.run("kill", ["-0", String(pid)]);
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
      ["--version", `p21-installed-${label}`],
      { env, stdio: ["ignore", log, log] },
    );
    process.unref();
    fs.closeSync(log);
    child = process;
    await waitFor(`P-21 daemon ${label}`, () => {
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
        "P-21 could not determine the user daemon state",
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
    async stopForSourceLoss() {
      await stopChild();
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
  const file = path.join(output, `.p21-atspi-${suffix}.json`);
  const args = [CONTROL, "--mode", mode, "--output", file];
  if (name) args.push("--name", name);
  required(runner, "python3", args, `P-21 AT-SPI ${suffix}`);
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
function selected(tree, text) {
  return (tree.nodes ?? []).some(
    (node) =>
      String(node.name ?? "").includes(text) &&
      (node.states ?? []).some((state) =>
        ["checked", "pressed", "selected"].includes(state),
      ),
  );
}
function defaultUI(runner, options) {
  let app = null;
  return {
    async launch() {
      app = runner.start(DESKTOP, [], { env: environment(options) });
      assert(
        Number.isSafeInteger(app.pid) && app.pid > 1,
        "P-21 desktop returned no PID",
      );
      await waitFor("P-21 installed desktop window", () => {
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
      atspi(runner, options.rawOutputDir, "route", "activate", "Insights");
      await sleep(800);
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
        `P-21 ${name}`,
      );
      assert(fs.statSync(file).size > 1024, `P-21 ${name} is empty`);
      return file;
    },
    async activate(name, suffix = "action") {
      const result = atspi(
        runner,
        options.rawOutputDir,
        suffix,
        "activate",
        name,
      );
      await sleep(600);
      return result;
    },
    async stop() {
      if (!app) return;
      const pid = app.pid;
      app.kill();
      await waitFor(`P-21 desktop PID ${pid} exit`, () => {
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

export async function runP21NativeInsightsProbes(options, dependencies = {}) {
  assert(
    (dependencies.platform ?? process.platform) === "linux",
    "P-21 native probe must execute on Linux",
  );
  assert(
    dependencies.desktopSession ??
      (process.env.DBUS_SESSION_BUS_ADDRESS && process.env.DISPLAY),
    "P-21 requires a live Linux X11 desktop and D-Bus session",
  );
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  options.rawOutputDir = ownerOnlyDirectory(
    options.rawOutputDir,
    "P-21 raw output",
    { empty: true },
  );
  options.supportDir = ownerOnlyDirectory(
    options.supportDir,
    "P-21 support directory",
  );
  options.homeDir = ownerOnlyDirectory(options.homeDir, "P-21 isolated home", {
    empty: true,
  });
  const authToken = readToken(options.tokenFile);
  assert(
    path.dirname(fs.realpathSync(options.tokenFile)) === options.supportDir,
    "P-21 token must be inside support directory",
  );
  assert(
    JSON.stringify(fs.readdirSync(options.supportDir).sort()) ===
      JSON.stringify([path.basename(options.tokenFile)]),
    "P-21 support directory must contain only its token",
  );
  assert(
    fs.realpathSync(path.dirname(options.indexDatabase)) ===
      options.supportDir && !fs.existsSync(options.indexDatabase),
    "P-21 index database must be a missing support-directory child",
  );
  const runner = dependencies.runner ?? commandRunner();
  const processIDs = (
    dependencies.desktopProcessIDs ?? (() => installedDesktopPids(runner))
  )();
  assert(
    Array.isArray(processIDs) && processIDs.length === 0,
    "P-21 requires no pre-existing installed desktop process",
  );
  if (!dependencies.ui)
    for (const command of ["python3", "xdotool", "scrot"])
      required(
        runner,
        "sh",
        ["-c", 'command -v "$1" >/dev/null', "p21-tool", command],
        `required tool ${command}`,
      );

  const marker =
    dependencies.marker ?? `p21-${crypto.randomBytes(8).toString("hex")}`;
  const prompt = `Summarize installed Insights evidence for ${marker}.`;
  const projectName = `P21 installed insights ${marker}`;
  const usageEvents = [
    ["codex", "gpt-5.6-sol", 840, 210, 160],
    ["claude", "claude-opus-4.6", 610, 190, 90],
    ["gemini", "gemini-3-pro", 430, 120, 40],
  ].map(
    (
      [providerID, modelID, inputTokens, outputTokens, cacheReadTokens],
      index,
    ) => ({
      idempotencyKey: `${marker}-${index}`,
      event: {
        providerID,
        modelID,
        inputTokens,
        outputTokens,
        cacheCreationTokens: 20 + index,
        cacheReadTokens,
        reasoningTokens: 30 + index,
        cost: 0.01 + index * 0.005,
        recordedAt: Date.now() / 1_000 - APPLE_REFERENCE_SECONDS - index,
        sessionID: `${marker}-session-${index}`,
        projectName,
        confidence: "exact",
      },
    }),
  );
  const daemon = dependencies.daemon ?? daemonController(runner, options);
  const rpc = dependencies.rpc ?? rpcClient(options, authToken);
  const ui = dependencies.ui ?? defaultUI(runner, options);
  const events = [];
  const uiEvents = [];
  const clock = { value: 0 };
  let app = null;
  let prepared = false;
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
  const observe = (phase, observed) =>
    uiEvents.push({
      phase,
      at: now(clock),
      appPid: app.pid,
      marker,
      manifestSha256: options.manifestSha256,
      observed,
    });
  const request = { limit: 200, windowSeconds: 604800, prompt };
  try {
    await daemon.prepare();
    prepared = true;
    for (const seeded of usageEvents) {
      const result = await call(
        `record-${seeded.event.providerID}`,
        "daemon.usage.record",
        seeded,
      );
      assert(
        result.inserted === true &&
          result.idempotencyKey === seeded.idempotencyKey,
        "P-21 daemon did not insert usage row",
      );
    }
    const initial = await call(
      "insights-initial",
      "daemon.usage.insights",
      request,
    );
    assert(
      initial.sourceID === "daemon.usage.ledger" && initial.usage?.length >= 3,
      "P-21 daemon returned no populated Insights response",
    );
    assert(
      initial.analysis?.executiveSummary &&
        initial.analysis?.citations?.length > 0,
      "P-21 daemon returned no qualitative evidence",
    );

    app = await ui.launch();
    const initialTree = ui.snapshot("initial");
    const initialObserved = {
      workspace: includes(initialTree, "Usage observatory"),
      provenance: includes(initialTree, "Provenance:"),
      qualitative: includes(initialTree, "Daemon qualitative brief"),
      fresh: includes(initialTree, "Fresh"),
      citation: includes(initialTree, "Open citation:"),
      inspector: includes(initialTree, "Insight inspector"),
    };
    assert(
      Object.values(initialObserved).every(Boolean),
      "P-21 initial Insights workspace is incomplete",
    );
    observe("initial", initialObserved);
    ui.screenshot("insights-initial.png");

    await ui.activate("Model mix", "select-model");
    await ui.activate("Compact", "compact");
    await call("insights-refresh", "daemon.usage.insights", request);
    await ui.activate("Refresh insights", "refresh");
    await ui.activate("Compare", "compare");
    for (const provider of usageEvents.map((row) => row.event.providerID)) {
      const label = provider.charAt(0).toUpperCase() + provider.slice(1);
      await ui.activate(`Provider scope: ${label}`, `compare-${provider}`);
    }
    const compareTree = ui.snapshot("configured");
    ui.screenshot("insights-compare.png");
    await ui.activate("Audit", "audit");
    const auditTree = ui.snapshot("audit");
    const configuredObserved = {
      compact: selected(compareTree, "Compact"),
      selectedWidget: selected(compareTree, "Model mix") ? "Model mix" : null,
      compareCount: includes(compareTree, "3 of 3 selected") ? 3 : 0,
      comparison: includes(compareTree, "Side-by-side comparison"),
      provenanceColumns: names(compareTree).filter((name) =>
        name.includes("Provenance:"),
      ).length,
      audit: includes(auditTree, "Insights audit"),
    };
    assert(
      configuredObserved.compareCount === 3 &&
        configuredObserved.comparison &&
        configuredObserved.audit,
      "P-21 configured workspace did not expose compare and audit state",
    );
    observe("configured", configuredObserved);
    await ui.activate("Close", "close-audit");

    const citationLabel = initial.analysis.citations[0].label;
    await ui.activate(`Open citation: ${citationLabel}`, "citation");
    const chatTree = ui.snapshot("chat-handoff");
    const chatObserved = {
      chat: includes(chatTree, "Chat"),
      followUp:
        includes(chatTree, "Explain the Insights evidence") ||
        includes(chatTree, citationLabel),
    };
    assert(
      chatObserved.chat && chatObserved.followUp,
      "P-21 citation did not hand off to Chat",
    );
    observe("chat-handoff", chatObserved);
    await ui.stop();
    app = null;

    await daemon.restart();
    await call("insights-restart", "daemon.usage.insights", request);
    app = await ui.launch();
    const restartTree = ui.snapshot("restart");
    const restartObserved = {
      compact: selected(restartTree, "Compact"),
      selectedWidget: selected(restartTree, "Model mix") ? "Model mix" : null,
    };
    assert(
      restartObserved.compact && restartObserved.selectedWidget === "Model mix",
      "P-21 workspace did not persist across restart",
    );
    observe("restart", restartObserved);
    ui.screenshot("insights-restart.png");

    await daemon.stopForSourceLoss();
    await ui.activate("Refresh insights", "source-loss-refresh");
    await sleep(1_000);
    const lossTree = ui.snapshot("source-loss");
    const lossObserved = {
      snapshotPreserved:
        includes(lossTree, "Usage observatory") &&
        includes(lossTree, "Model mix"),
      degradedBanner: includes(
        lossTree,
        "Showing the last successful Insights snapshot",
      ),
    };
    assert(
      lossObserved.snapshotPreserved && lossObserved.degradedBanner,
      "P-21 source loss did not preserve the last snapshot",
    );
    observe("source-loss", lossObserved);
    ui.screenshot("insights-source-loss.png");

    writeJson(path.join(options.rawOutputDir, "insights-marker.json"), {
      marker,
      prompt,
      events: usageEvents,
    });
    writeJson(
      path.join(options.rawOutputDir, "insights-daemon-transcript.json"),
      {
        producer: "openburnbar-p21-installed-insights-daemon-probe-v1",
        transport: "installed daemon AF_UNIX RPC",
        events,
      },
    );
    writeJson(path.join(options.rawOutputDir, "insights-ui-transcript.json"), {
      producer: "openburnbar-p21-installed-insights-ui-probe-v1",
      events: uiEvents,
    });
    return { output: options.rawOutputDir, marker };
  } finally {
    try {
      if (app) await ui.stop();
    } catch {
      /* preserve primary failure */
    }
    if (prepared) await daemon.restore();
  }
}

export function parseP21Arguments(argv) {
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
      `${JSON.stringify(await runP21NativeInsightsProbes(parseP21Arguments(process.argv.slice(2))), null, 2)}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-21 native Insights probe failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
