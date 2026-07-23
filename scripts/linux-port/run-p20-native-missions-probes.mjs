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
const CONTROL = path.join(ROOT, "scripts/linux-port/p20-atspi-control.py");

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
      "P-20 daemon token must be an owner-only regular file",
    );
    const value = fs.readFileSync(fd, "utf8").trim();
    assert(
      value.length >= 32 && !/[\r\n]/u.test(value),
      "P-20 daemon token is invalid",
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
    `P-20 desktop preflight failed: ${(result.stderr || result.stdout).trim()}`,
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
        finish(reject, new Error(`P-20 RPC timed out: ${method}`)),
      );
      socket.on("error", (error) => finish(reject, error));
      socket.on("connect", () =>
        socket.write(
          `${JSON.stringify({
            protocolVersion: 1,
            id: `p20-${++sequence}`,
            method,
            traceId: `p20-trace-${sequence}`,
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
              new Error(document.error.message ?? `P-20 RPC failed: ${method}`),
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
    await waitFor(`P-20 daemon PID ${child.pid} exit`, () => {
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
      ["--version", `p20-installed-${label}`],
      { env, stdio: ["ignore", log, log] },
    );
    process.unref();
    fs.closeSync(log);
    child = process;
    await waitFor(`P-20 daemon ${label}`, () => {
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
        "P-20 could not determine the user daemon state",
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
function atspi(runner, output, suffix, mode, name = null, actionName = null) {
  const file = path.join(output, `.p20-atspi-${suffix}.json`);
  const args = [CONTROL, "--mode", mode, "--output", file];
  if (name) args.push("--name", name);
  if (actionName) args.push("--action-name", actionName);
  required(runner, "python3", args, `P-20 AT-SPI ${suffix}`);
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
        "P-20 desktop returned no PID",
      );
      await waitFor("P-20 installed desktop window", () => {
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
      atspi(runner, options.rawOutputDir, "route", "activate", "Missions");
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
        `P-20 ${name}`,
      );
      assert(fs.statSync(file).size > 1024, `P-20 ${name} is empty`);
      return file;
    },
    async activate(name, label) {
      const result = atspi(
        runner,
        options.rawOutputDir,
        label,
        "activate",
        name,
      );
      await sleep(700);
      return result;
    },
    async stop() {
      if (!app) return;
      const pid = app.pid;
      app.kill();
      await waitFor(`P-20 desktop PID ${pid} exit`, () => {
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

export async function runP20NativeMissionsProbes(options, dependencies = {}) {
  assert(
    (dependencies.platform ?? process.platform) === "linux",
    "P-20 native probe must execute on Linux",
  );
  assert(
    dependencies.desktopSession ??
      (process.env.DBUS_SESSION_BUS_ADDRESS && process.env.DISPLAY),
    "P-20 requires a live Linux X11 desktop and D-Bus session",
  );
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  options.rawOutputDir = ownerOnlyDirectory(
    options.rawOutputDir,
    "P-20 raw output",
    { empty: true },
  );
  options.supportDir = ownerOnlyDirectory(
    options.supportDir,
    "P-20 support directory",
  );
  options.homeDir = ownerOnlyDirectory(options.homeDir, "P-20 isolated home", {
    empty: true,
  });
  const authToken = token(options.tokenFile);
  assert(
    path.dirname(fs.realpathSync(options.tokenFile)) === options.supportDir,
    "P-20 token must be inside support directory",
  );
  assert(
    JSON.stringify(fs.readdirSync(options.supportDir).sort()) ===
      JSON.stringify([path.basename(options.tokenFile)]),
    "P-20 support directory must contain only its token",
  );
  assert(
    path.dirname(path.resolve(options.indexDatabase)) === options.supportDir &&
      !fs.existsSync(options.indexDatabase),
    "P-20 index database must be a missing support-directory child",
  );
  const runner = dependencies.runner ?? commandRunner();
  const processIDs = (
    dependencies.desktopProcessIDs ?? (() => installedDesktopPids(runner))
  )();
  assert(
    Array.isArray(processIDs) && processIDs.length === 0,
    "P-20 requires no pre-existing installed desktop process",
  );
  if (!dependencies.ui)
    for (const command of ["python3", "xdotool", "scrot"])
      required(
        runner,
        "sh",
        ["-c", 'command -v "$1" >/dev/null', "p20-tool", command],
        `required tool ${command}`,
      );
  const marker =
    dependencies.marker ?? `p20-${crypto.randomBytes(8).toString("hex")}`;
  const projectSlug = `${marker}-project`;
  const missionTitle = `P20 Mission ${marker}`;
  const questionTitle = `P20 Question ${marker}`;
  const optionTitle = `Proceed ${marker}`;
  const optionAnswer = `Proceed with ${marker}`;
  const project = {
    id: `project:${projectSlug}`,
    projectSlug,
    displayName: `P20 Project ${marker}`,
    summary: `Mission lifecycle project ${marker}`,
    status: "healthy",
    preferredCadence: "weekly",
    aliases: [`${marker}:project-alias`],
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
    metadata: { p20_marker: marker },
  };
  const daemon = dependencies.daemon ?? daemonController(runner, options);
  const rpc = dependencies.rpc ?? rpcClient(options, authToken);
  const ui = dependencies.ui ?? defaultUI(runner, options);
  const events = [];
  const uiEvents = [];
  const uiActions = [];
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
  const launchAndSnapshot = async (phase, observed) => {
    app = await ui.launch();
    const tree = ui.snapshot(phase);
    const event = {
      phase,
      at: now(clock),
      appPid: app.pid,
      marker,
      projectSlug,
      missionTitle,
      questionTitle,
      manifestSha256: options.manifestSha256,
      observed: observed(tree),
    };
    uiEvents.push(event);
    return tree;
  };
  try {
    await daemon.prepare();
    prepared = true;
    const upsert = await call(
      "project-upserted",
      "daemon.controller.project.upsert",
      { project },
    );
    assert(
      upsert.project?.projectSlug === projectSlug,
      "P-20 project upsert did not preserve identity",
    );
    const createdMission = await call(
      "mission-created",
      "daemon.mission.create",
      {
        projectSlug,
        title: missionTitle,
        summary: `Verify approval, execution evidence, persistence, and cancellation ${marker}`,
        createdBy: "linux-parity-p20",
        recommendation: "review",
        metadata: { p20_marker: marker },
      },
    );
    const missionID = createdMission.mission?.id;
    assert(
      typeof missionID === "string" &&
        missionID.length > 0 &&
        createdMission.mission?.projectSlug === projectSlug &&
        createdMission.mission?.status === "awaiting_approval",
      "P-20 failed to create a pending mission",
    );
    const listed = await call("mission-listed", "daemon.mission.list", {
      projectSlug,
      statuses: ["awaiting_approval"],
      limit: 100,
    });
    assert(
      listed.missions?.some((mission) => mission.id === missionID),
      "P-20 list omitted the pending mission",
    );

    const initialTree = await launchAndSnapshot("pending-approval", (tree) => ({
      missionVisible: includes(tree, missionTitle),
      pendingVisible: includes(tree, "Pending approvals"),
      approveAction: includes(tree, `Approve ${missionTitle}`),
    }));
    assert(
      includes(initialTree, missionTitle) &&
        includes(initialTree, `Approve ${missionTitle}`),
      "P-20 installed UI omitted the pending approval",
    );
    ui.screenshot("missions-pending.png");
    uiActions.push({
      phase: "approve",
      at: now(clock),
      result: await ui.activate(`Approve ${missionTitle}`, "approve"),
    });
    await waitFor("P-20 mission approval readback", async () => {
      const snapshot = await rpc("daemon.mission.get", { missionID });
      assert(
        snapshot.mission?.status === "approved" &&
          snapshot.mission?.approval?.approved === true,
        "mission approval is not durable yet",
      );
      return true;
    });
    const approved = await call(
      "mission-approved-readback",
      "daemon.mission.get",
      { missionID },
    );
    assert(
      approved.mission?.status === "approved" &&
        approved.mission?.approval?.approved === true,
      "P-20 UI approval did not round-trip through the daemon",
    );
    const approvedTree = await waitFor("P-20 approved UI state", () => {
      const tree = ui.snapshot("approved-wait");
      assert(includes(tree, "Approved"), "approved state is not visible yet");
      return tree;
    });
    assert(
      includes(approvedTree, missionTitle),
      "P-20 approved mission disappeared from the UI",
    );
    uiEvents.push({
      phase: "approved",
      at: now(clock),
      appPid: app.pid,
      marker,
      projectSlug,
      missionTitle,
      questionTitle,
      manifestSha256: options.manifestSha256,
      observed: {
        missionVisible: true,
        approvalSubmitted: true,
        approvedVisible: true,
      },
    });
    ui.screenshot("missions-approved.png");
    await ui.stop();
    app = null;

    const packetID = `packet:${marker}`;
    const runID = `run:${marker}`;
    const foundationNow = Date.now() / 1000 - 978_307_200;
    const dispatched = await call(
      "packet-dispatched",
      "daemon.mission.packet.dispatch",
      {
        missionID,
        actor: "linux-parity-p20",
        packet: {
          id: packetID,
          missionID,
          workerName: "linux-parity-worker",
          objective: `Execute ${marker}`,
          status: "dispatched",
          runID,
          dispatchedAt: foundationNow,
          completedAt: null,
          metadata: { p20_marker: marker },
        },
      },
    );
    assert(
      dispatched.mission?.packets?.some((packet) => packet.id === packetID),
      "P-20 packet dispatch did not persist",
    );
    const resultID = `result:${marker}`;
    const recorded = await call(
      "result-recorded",
      "daemon.mission.result.record",
      {
        missionID,
        result: {
          id: resultID,
          missionID,
          packetID,
          runID,
          status: "succeeded",
          summary: `Completed ${marker}`,
          detail: `Installed Linux evidence ${marker}`,
          burnDelta: 12.5,
          createdAt: foundationNow + 1,
          evidenceRefs: [`evidence:${marker}`],
          prLinkage: {
            schemaVersion: 1,
            repository: "openburnbar/openburnbar",
            prNumberOrID: "20",
            url: "https://github.com/openburnbar/openburnbar/pull/20",
            state: "merged",
            mergeCommitSHA: "2".repeat(40),
            mergedAt: foundationNow + 1,
            closedAt: null,
          },
          metadata: { p20_marker: marker, burn_unit: "tokens" },
        },
      },
    );
    assert(
      recorded.mission?.results?.some((result) => result.id === resultID) &&
        recorded.mission?.prLinkage?.prNumberOrID === "20",
      "P-20 result/evidence/PR linkage did not persist",
    );
    const health = await call("mission-health", "daemon.mission.health", {
      missionID,
    });
    assert(
      health.missionID === missionID &&
        health.health &&
        Array.isArray(health.history) &&
        health.history.length >= 3,
      "P-20 health/history projection is incomplete",
    );

    const questionID = `question:${marker}`;
    const question = {
      id: questionID,
      projectSlug,
      sessionID: null,
      title: questionTitle,
      prompt: `Should ${marker} proceed?`,
      stageLabel: "Verification",
      status: "pending",
      priority: "high",
      askedAt: foundationNow + 2,
      dueAt: null,
      latestAnswer: null,
      answerPlaceholder: "Choose a verified answer",
      contextSummary: `Mission ${missionTitle}`,
      evidenceRefs: [`evidence:${marker}`],
      suggestedOptions: [
        {
          id: `option:${marker}`,
          title: optionTitle,
          detail: "Use the verified mission result",
          answer: optionAnswer,
          metadata: { p20_marker: marker },
        },
      ],
      deepLink: null,
      tracker: null,
      metadata: { p20_marker: marker },
    };
    const createdQuestion = await call(
      "question-created",
      "daemon.question.create",
      { question },
    );
    assert(
      createdQuestion.question?.id === questionID,
      "P-20 pending question was not created",
    );
    const questionTree = await launchAndSnapshot(
      "pending-question",
      (tree) => ({
        questionVisible: includes(tree, questionTitle),
        suggestedAnswerVisible: includes(tree, optionTitle),
        submitVisible: includes(tree, "Submit answer"),
      }),
    );
    assert(
      includes(questionTree, questionTitle) &&
        includes(questionTree, optionTitle),
      "P-20 UI omitted the pending question or suggested answer",
    );
    ui.screenshot("missions-question.png");
    uiActions.push({
      phase: "question-option",
      at: now(clock),
      result: await ui.activate(optionTitle, "question-option"),
    });
    uiActions.push({
      phase: "question-submit",
      at: now(clock),
      result: await ui.activate("Submit answer", "question-submit"),
    });
    await waitFor("P-20 question answer readback", async () => {
      const snapshot = await rpc("daemon.question.list", {
        projectSlug,
        statuses: ["answered"],
        limit: 100,
      });
      assert(
        snapshot.questions?.some(
          (item) =>
            item.id === questionID &&
            item.latestAnswer?.answer === optionAnswer &&
            item.latestAnswer?.selectedOptionID === `option:${marker}`,
        ),
        "question answer is not durable yet",
      );
      return true;
    });
    const answered = await call(
      "question-answered-readback",
      "daemon.question.list",
      { projectSlug, statuses: ["answered"], limit: 100 },
    );
    assert(
      answered.questions?.some(
        (item) =>
          item.id === questionID &&
          item.latestAnswer?.answer === optionAnswer &&
          item.latestAnswer?.selectedOptionID === `option:${marker}`,
      ),
      "P-20 UI question answer did not round-trip through the daemon",
    );
    await ui.stop();
    app = null;

    await daemon.restart();
    const restartMission = await call(
      "restart-mission-get",
      "daemon.mission.get",
      { missionID },
    );
    assert(
      restartMission.mission?.id === missionID &&
        restartMission.mission?.packets?.some(
          (packet) => packet.id === packetID,
        ) &&
        restartMission.mission?.results?.some(
          (result) => result.id === resultID,
        ),
      "P-20 restart replay lost mission execution evidence",
    );
    const restartHealth = await call(
      "restart-mission-health",
      "daemon.mission.health",
      { missionID },
    );
    assert(
      restartHealth.history?.length >= health.history.length,
      "P-20 restart replay lost mission history",
    );
    const restartTree = await launchAndSnapshot("restart-detail", (tree) => ({
      missionVisible: includes(tree, missionTitle),
      inspectVisible: includes(tree, "Inspect logs"),
      cancelVisible: includes(tree, "Cancel mission"),
    }));
    assert(
      includes(restartTree, missionTitle) &&
        includes(restartTree, "Inspect logs"),
      "P-20 restart UI omitted the durable mission",
    );
    uiActions.push({
      phase: "inspect-logs",
      at: now(clock),
      result: await ui.activate("Inspect logs", "inspect-logs"),
    });
    const detailTree = ui.snapshot("mission-detail");
    assert(
      includes(detailTree, "Packets / tasks") &&
        includes(detailTree, "Results / evidence") &&
        includes(detailTree, "Controller history") &&
        includes(detailTree, `evidence:${marker}`),
      "P-20 mission detail omitted execution evidence or history",
    );
    uiEvents.push({
      phase: "mission-detail",
      at: now(clock),
      appPid: app.pid,
      marker,
      projectSlug,
      missionTitle,
      questionTitle,
      manifestSha256: options.manifestSha256,
      observed: {
        packetVisible: includes(detailTree, "Packets / tasks"),
        resultVisible: includes(detailTree, "Results / evidence"),
        historyVisible: includes(detailTree, "Controller history"),
      },
    });
    ui.screenshot("missions-detail.png");
    uiActions.push({
      phase: "cancel-start",
      at: now(clock),
      result: await ui.activate("Cancel mission", "cancel-start"),
    });
    uiActions.push({
      phase: "cancel-confirm",
      at: now(clock),
      result: await ui.activate("Confirm cancel", "cancel-confirm"),
    });
    await waitFor("P-20 mission cancellation readback", async () => {
      const snapshot = await rpc("daemon.mission.get", { missionID });
      assert(
        snapshot.mission?.status === "cancelled",
        "mission cancellation is not durable yet",
      );
      return true;
    });
    const cancelled = await call(
      "mission-cancelled-readback",
      "daemon.mission.get",
      { missionID },
    );
    assert(
      cancelled.mission?.status === "cancelled",
      "P-20 UI cancellation did not round-trip through the daemon",
    );
    const cancelledTree = await waitFor("P-20 cancelled UI state", () => {
      const tree = ui.snapshot("cancelled-wait");
      assert(includes(tree, "Cancelled"), "cancelled state is not visible yet");
      return tree;
    });
    assert(
      includes(cancelledTree, missionTitle) &&
        includes(cancelledTree, "Cancelled"),
      "P-20 cancelled state is not visible",
    );
    uiEvents.push({
      phase: "cancelled",
      at: now(clock),
      appPid: app.pid,
      marker,
      projectSlug,
      missionTitle,
      questionTitle,
      manifestSha256: options.manifestSha256,
      observed: { missionVisible: true, cancelledVisible: true },
    });
    ui.screenshot("missions-cancelled.png");
    writeJson(path.join(options.rawOutputDir, "missions-marker.json"), {
      marker,
      projectSlug,
      project,
      missionID,
      missionTitle,
      packetID,
      resultID,
      questionID,
      questionTitle,
      optionID: `option:${marker}`,
      optionTitle,
      optionAnswer,
    });
    writeJson(
      path.join(options.rawOutputDir, "missions-daemon-transcript.json"),
      {
        producer: "openburnbar-p20-installed-missions-daemon-probe-v1",
        transport: "installed daemon AF_UNIX RPC",
        events,
      },
    );
    writeJson(path.join(options.rawOutputDir, "missions-ui-transcript.json"), {
      producer: "openburnbar-p20-installed-missions-ui-probe-v1",
      events: uiEvents,
      actions: uiActions,
    });
    return { output: options.rawOutputDir, marker, projectSlug, missionID };
  } finally {
    try {
      if (app) await ui.stop();
    } catch {
      /* preserve primary failure */
    }
    if (prepared) await daemon.restore();
  }
}

export function parseP20Arguments(argv) {
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
      `${JSON.stringify(await runP20NativeMissionsProbes(parseP20Arguments(process.argv.slice(2))), null, 2)}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-20 native Missions probe failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
