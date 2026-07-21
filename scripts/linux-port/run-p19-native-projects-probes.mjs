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
const CONTROL = path.join(ROOT, "scripts/linux-port/p19-atspi-control.py");

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
  const stat = fs.lstatSync(file);
  assert(
    stat.isFile() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    "P-19 daemon token must be an owner-only regular file",
  );
  const value = fs.readFileSync(file, "utf8").trim();
  assert(
    value.length >= 32 && !/[\r\n]/u.test(value),
    "P-19 daemon token is invalid",
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
    `P-19 desktop preflight failed: ${(result.stderr || result.stdout).trim()}`,
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
        finish(reject, new Error(`P-19 RPC timed out: ${method}`)),
      );
      socket.on("error", (error) => finish(reject, error));
      socket.on("connect", () =>
        socket.write(
          `${JSON.stringify({
            protocolVersion: 1,
            id: `p19-${++sequence}`,
            method,
            traceId: `p19-trace-${sequence}`,
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
              new Error(document.error.message ?? `P-19 RPC failed: ${method}`),
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
    await waitFor(`P-19 daemon PID ${child.pid} exit`, () => {
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
      ["--version", `p19-installed-${label}`],
      { env, stdio: ["ignore", log, log] },
    );
    process.unref();
    fs.closeSync(log);
    child = process;
    await waitFor(`P-19 daemon ${label}`, () => {
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
        "P-19 could not determine the user daemon state",
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
function atspi(
  runner,
  output,
  suffix,
  mode,
  name = null,
  actionName = null,
) {
  const file = path.join(output, `.p19-atspi-${suffix}.json`);
  const args = [CONTROL, "--mode", mode, "--output", file];
  if (name) args.push("--name", name);
  if (actionName) args.push("--action-name", actionName);
  required(runner, "python3", args, `P-19 AT-SPI ${suffix}`);
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
        "P-19 desktop returned no PID",
      );
      await waitFor("P-19 installed desktop window", () => {
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
      atspi(runner, options.rawOutputDir, "route", "activate", "Projects");
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
        `P-19 ${name}`,
      );
      assert(fs.statSync(file).size > 1024, `P-19 ${name} is empty`);
      return file;
    },
    async openProject(displayName) {
      atspi(
        runner,
        options.rawOutputDir,
        "open-details",
        "activate-related",
        displayName,
        "Open details",
      );
      await sleep(600);
    },
    async stop() {
      if (!app) return;
      const pid = app.pid;
      app.kill();
      await waitFor(`P-19 desktop PID ${pid} exit`, () => {
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

export async function runP19NativeProjectsProbes(options, dependencies = {}) {
  assert(
    (dependencies.platform ?? process.platform) === "linux",
    "P-19 native probe must execute on Linux",
  );
  assert(
    dependencies.desktopSession ??
      (process.env.DBUS_SESSION_BUS_ADDRESS && process.env.DISPLAY),
    "P-19 requires a live Linux X11 desktop and D-Bus session",
  );
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  options.rawOutputDir = ownerOnlyDirectory(
    options.rawOutputDir,
    "P-19 raw output",
    { empty: true },
  );
  options.supportDir = ownerOnlyDirectory(
    options.supportDir,
    "P-19 support directory",
  );
  options.homeDir = ownerOnlyDirectory(options.homeDir, "P-19 isolated home", {
    empty: true,
  });
  const authToken = token(options.tokenFile);
  assert(
    path.dirname(fs.realpathSync(options.tokenFile)) === options.supportDir,
    "P-19 token must be inside support directory",
  );
  assert(
    JSON.stringify(fs.readdirSync(options.supportDir).sort()) ===
      JSON.stringify([path.basename(options.tokenFile)]),
    "P-19 support directory must contain only its token",
  );
  assert(
    path.dirname(path.resolve(options.indexDatabase)) === options.supportDir &&
      !fs.existsSync(options.indexDatabase),
    "P-19 index database must be a missing support-directory child",
  );
  const runner = dependencies.runner ?? commandRunner();
  const processIDs = (
    dependencies.desktopProcessIDs ?? (() => installedDesktopPids(runner))
  )();
  assert(
    Array.isArray(processIDs) && processIDs.length === 0,
    "P-19 requires no pre-existing installed desktop process",
  );
  if (!dependencies.ui)
    for (const command of ["python3", "xdotool", "scrot"])
      required(
        runner,
        "sh",
        ["-c", 'command -v "$1" >/dev/null', "p19-tool", command],
        `required tool ${command}`,
      );
  const marker =
    dependencies.marker ?? `p19-${crypto.randomBytes(8).toString("hex")}`;
  const sourceSlug = `${marker}-source`;
  const targetSlug = `${marker}-target`;
  const sourceAlias = `${marker}:source-alias`;
  const sourceProject = {
    id: `project:${sourceSlug}`,
    projectSlug: sourceSlug,
    displayName: `P19 Source ${marker}`,
    summary: `Project lifecycle source ${marker}`,
    status: "healthy",
    preferredCadence: "weekly",
    aliases: [sourceAlias],
    automationMode: "manual",
    reviewModelID: null,
    scheduleHourLocal: 9,
    scheduleWeekdayLocal: 2,
    freshness: "provisional",
    latestDailyReviewAt: null,
    latestWeeklyReviewAt: null,
    nextScheduledReviewAt: null,
    pendingQuestionCount: 0,
    openFollowupCount: 0,
    activeMissionCount: 0,
    activeMissionID: null,
    needsOperatorAttention: false,
    ingestionSource: "manual",
    metadata: { p19_marker: marker },
  };
  const targetProject = {
    ...sourceProject,
    id: `project:${targetSlug}`,
    projectSlug: targetSlug,
    displayName: `P19 Target ${marker}`,
    summary: `Project lifecycle target ${marker}`,
    aliases: [`${marker}:target-alias`],
  };
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
  const callFailure = async (phase, method, request) => {
    try {
      await call(phase, method, request);
    } catch (error) {
      return error.message;
    }
    throw new Error(`P-19 expected ${method} to reject ${phase}`);
  };
  const launchAndSnapshot = async (phase, observed) => {
    app = await ui.launch();
    const tree = ui.snapshot(phase);
    const event = {
      phase,
      at: now(clock),
      appPid: app.pid,
      marker,
      sourceSlug,
      targetSlug,
      manifestSha256: options.manifestSha256,
      observed: observed(tree),
    };
    uiEvents.push(event);
    return tree;
  };
  try {
    await daemon.prepare();
    prepared = true;
    const sourceUpsert = await call(
      "source-upserted",
      "daemon.controller.project.upsert",
      { project: sourceProject },
    );
    const targetUpsert = await call(
      "target-upserted",
      "daemon.controller.project.upsert",
      { project: targetProject },
    );
    assert(
      sourceUpsert.project?.projectSlug === sourceSlug &&
        targetUpsert.project?.projectSlug === targetSlug,
      "P-19 upsert responses did not preserve project identities",
    );
    const initialList = await call(
      "initial-list",
      "daemon.controller.project.list",
      { includePaused: true, limit: 100 },
    );
    assert(
      initialList.projects?.some((project) => project.projectSlug === sourceSlug) &&
        initialList.projects?.some((project) => project.projectSlug === targetSlug),
      "P-19 list did not return both upserted projects",
    );
    const sourceGet = await call(
      "source-get-by-alias",
      "daemon.controller.project.get",
      { projectSlug: sourceAlias },
    );
    assert(
      sourceGet.project?.projectSlug === sourceSlug,
      "P-19 get did not resolve the source alias",
    );
    const createdMission = await call(
      "associated-mission-created",
      "daemon.mission.create",
      {
        projectSlug: sourceSlug,
        title: `P19 associated mission ${marker}`,
        summary: `Verify durable project reassignment ${marker}`,
        createdBy: "linux-parity-p19",
        recommendation: "review",
        metadata: { p19_marker: marker },
      },
    );
    const missionID = createdMission.mission?.id;
    assert(
      typeof missionID === "string" &&
        missionID.length > 0 &&
        createdMission.mission?.projectSlug === sourceSlug,
      "P-19 failed to create a real source-project association",
    );
    const initialTree = await launchAndSnapshot("initial", (tree) => ({
      sourceVisible: includes(tree, sourceProject.displayName),
      targetVisible: includes(tree, targetProject.displayName),
      detailsAction: includes(tree, "Open details"),
      registerAction: includes(tree, "Register project"),
    }));
    assert(
      includes(initialTree, sourceProject.displayName) &&
        includes(initialTree, targetProject.displayName),
      "P-19 installed Projects UI omitted an upserted project",
    );
    ui.screenshot("projects-initial.png");
    await ui.stop();
    app = null;

    const deleted = await call(
      "source-deleted",
      "daemon.controller.project.delete",
      { projectSlug: sourceSlug },
    );
    assert(
      deleted.deleted === true && deleted.projectSlug === sourceSlug,
      "P-19 delete response did not confirm the source tombstone",
    );
    const reassigned = await call(
      "deleted-source-reassigned",
      "daemon.controller.project.reassign",
      { sourceProjectSlug: sourceAlias, targetProjectSlug: targetSlug },
    );
    assert(
        reassigned.sourceProjectSlug === sourceSlug &&
        reassigned.targetProjectSlug === targetSlug &&
        Number.isInteger(reassigned.updatedReferenceCount) &&
        reassigned.updatedReferenceCount >= 1,
      "P-19 reassign response did not migrate a real project association",
    );
    const reassignedMission = await call(
      "reassigned-mission-get",
      "daemon.mission.get",
      { missionID },
    );
    assert(
      reassignedMission.mission?.id === missionID &&
        reassignedMission.mission?.projectSlug === targetSlug,
      "P-19 mission association did not move to the target project",
    );
    const afterDelete = await call(
      "post-delete-list",
      "daemon.controller.project.list",
      { includePaused: true, limit: 100 },
    );
    assert(
      !afterDelete.projects?.some((project) => project.projectSlug === sourceSlug) &&
        afterDelete.projects?.some((project) => project.projectSlug === targetSlug),
      "P-19 deleted source remained in the project registry",
    );
    const deletedGet = await call(
      "post-delete-get",
      "daemon.controller.project.get",
      { projectSlug: sourceSlug },
    );
    assert(deletedGet.project === null, "P-19 deleted project remained readable");

    await daemon.restart();
    const restartList = await call(
      "restart-list",
      "daemon.controller.project.list",
      { includePaused: true, limit: 100 },
    );
    assert(
      !restartList.projects?.some((project) => project.projectSlug === sourceSlug) &&
        restartList.projects?.some((project) => project.projectSlug === targetSlug),
      "P-19 restart replay did not preserve project deletion",
    );
    const restartGet = await call(
      "restart-get-deleted",
      "daemon.controller.project.get",
      { projectSlug: sourceAlias },
    );
    assert(
      restartGet.project === null,
      "P-19 restart replay exposed the deleted project alias",
    );
    const restartMission = await call(
      "restart-mission-get",
      "daemon.mission.get",
      { missionID },
    );
    assert(
      restartMission.mission?.id === missionID &&
        restartMission.mission?.projectSlug === targetSlug,
      "P-19 restart replay lost the reassigned mission association",
    );
    await callFailure(
      "restart-upsert-rejected-by-tombstone",
      "daemon.controller.project.upsert",
      { project: sourceProject },
    );
    const restartReassign = await call(
      "restart-reassign-from-tombstone",
      "daemon.controller.project.reassign",
      { sourceProjectSlug: sourceAlias, targetProjectSlug: targetSlug },
    );
    assert(
      restartReassign.sourceProjectSlug === sourceSlug &&
        restartReassign.targetProjectSlug === targetSlug,
      "P-19 restart replay lost deleted-source reassignment semantics",
    );
    const restartTree = await launchAndSnapshot("restart-list", (tree) => ({
      sourceAbsent: !includes(tree, sourceProject.displayName),
      targetVisible: includes(tree, targetProject.displayName),
      detailsAction: includes(tree, "Open details"),
    }));
    assert(
      !includes(restartTree, sourceProject.displayName) &&
        includes(restartTree, targetProject.displayName),
      "P-19 restart UI did not reflect the durable registry state",
    );
    await ui.openProject(targetProject.displayName);
    const detailTree = ui.snapshot("restart-detail");
    assert(
      includes(detailTree, targetProject.displayName) &&
        includes(detailTree, "Project history"),
      "P-19 target project detail/history was absent after restart",
    );
    uiEvents.push({
      phase: "restart-detail",
      at: now(clock),
      appPid: app.pid,
      marker,
      sourceSlug,
      targetSlug,
      manifestSha256: options.manifestSha256,
      observed: {
        targetVisible: includes(detailTree, targetProject.displayName),
        historyVisible: includes(detailTree, "Project history"),
      },
    });
    ui.screenshot("projects-restart.png");
    writeJson(path.join(options.rawOutputDir, "projects-marker.json"), {
      marker,
      sourceSlug,
      targetSlug,
      sourceAlias,
      sourceProject,
      targetProject,
    });
    writeJson(
      path.join(options.rawOutputDir, "projects-daemon-transcript.json"),
      {
        producer: "openburnbar-p19-installed-projects-daemon-probe-v1",
        transport: "installed daemon AF_UNIX RPC",
        events,
      },
    );
    writeJson(path.join(options.rawOutputDir, "projects-ui-transcript.json"), {
      producer: "openburnbar-p19-installed-projects-ui-probe-v1",
      events: uiEvents,
    });
    return { output: options.rawOutputDir, marker, sourceSlug, targetSlug };
  } finally {
    try {
      if (app) await ui.stop();
    } catch {
      /* preserve primary failure */
    }
    if (prepared) await daemon.restore();
  }
}

export function parseP19Arguments(argv) {
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
      `${JSON.stringify(await runP19NativeProjectsProbes(parseP19Arguments(process.argv.slice(2))), null, 2)}\n`,
    );
  } catch (error) {
    process.stderr.write(`P-19 native Projects probe failed: ${error.message}\n`);
    process.exitCode = 1;
  }
}
