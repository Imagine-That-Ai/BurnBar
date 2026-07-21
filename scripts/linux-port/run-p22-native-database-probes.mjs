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
const CONTROL = path.join(ROOT, "scripts/linux-port/p22-atspi-control.py");
const MAX_SNAPSHOT_BYTES = 512 * 1024 * 1024;

function assert(value, message) {
  if (!value) throw new Error(message);
}
function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
function writeExclusive(file, bytes, mode = 0o600) {
  const fd = fs.openSync(
    file,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
    mode,
  );
  try {
    fs.writeFileSync(fd, bytes);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
}
function writeJson(file, value) {
  writeExclusive(file, Buffer.from(`${JSON.stringify(value, null, 2)}\n`));
}
function fileMetadata(file) {
  const bytes = fs.readFileSync(file);
  const stat = fs.statSync(file);
  return {
    path: file,
    byteCount: bytes.length,
    sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
    mode: (stat.mode & 0o777).toString(8).padStart(4, "0"),
  };
}
function privateDirectory(directory, label, { empty = false } = {}) {
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(directory);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    `${label} must be an owner-only real directory`,
  );
  const resolved = fs.realpathSync(directory);
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
    "P-22 daemon token must be owner-only",
  );
  const value = fs.readFileSync(file, "utf8").trim();
  assert(
    value.length >= 32 && !/[\r\n]/u.test(value),
    "P-22 daemon token is invalid",
  );
  return value;
}
function runner() {
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
      return { pid: child.pid, kill: () => child.kill() };
    },
  };
}
function required(commandRunner, command, args, label, options = {}) {
  const result = commandRunner.run(command, args, options);
  assert(
    result.status === 0,
    `${label} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout.trim();
}
function installedDesktopPids(commandRunner) {
  const result = commandRunner.run("pgrep", [
    "-f",
    "^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)",
  ]);
  if (result.status === 1) return [];
  assert(
    result.status === 0,
    `P-22 desktop preflight failed: ${(result.stderr || result.stdout).trim()}`,
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
      socket.setTimeout(120_000, () =>
        finish(reject, new Error(`P-22 RPC timed out: ${method}`)),
      );
      socket.on("error", (error) => finish(reject, error));
      socket.on("connect", () =>
        socket.write(
          `${JSON.stringify({
            protocolVersion: 1,
            id: `p22-${++sequence}`,
            method,
            traceId: `p22-trace-${sequence}`,
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
              new Error(document.error.message ?? `P-22 RPC failed: ${method}`),
            );
          else finish(resolve, document.result);
        } catch (error) {
          finish(reject, error);
        }
      });
    });
}
function daemonController(commandRunner, options) {
  let child = null;
  let wasActive = false;
  const env = environment(options);
  const stop = async () => {
    if (!child) return;
    const pid = child.pid;
    child.kill();
    await waitFor(`P-22 daemon PID ${pid} exit`, () => {
      const result = commandRunner.run("kill", ["-0", String(pid)]);
      assert(result.status !== 0, "daemon still running");
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
      ["--version", `p22-installed-${label}`],
      { env, stdio: ["ignore", log, log] },
    );
    process.unref();
    fs.closeSync(log);
    child = process;
    await waitFor(`P-22 daemon ${label}`, () => {
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
      const status = commandRunner.run("systemctl", [
        "--user",
        "is-active",
        "--quiet",
        "openburnbar-daemon.service",
      ]);
      wasActive = status.status === 0;
      assert(
        [0, 3].includes(status.status),
        "P-22 could not determine user daemon state",
      );
      if (wasActive)
        required(
          commandRunner,
          "systemctl",
          ["--user", "stop", "openburnbar-daemon.service"],
          "stop user daemon",
        );
      await launch("initial");
    },
    async restart() {
      await stop();
      await launch("restart");
    },
    async restore() {
      await stop();
      if (wasActive)
        required(
          commandRunner,
          "systemctl",
          ["--user", "start", "openburnbar-daemon.service"],
          "restore user daemon",
        );
    },
  };
}
function atspi(commandRunner, output, suffix, mode, name = null, value = null) {
  const file = path.join(output, `.p22-atspi-${suffix}.json`);
  const args = [CONTROL, "--mode", mode, "--output", file];
  if (name) args.push("--name", name);
  if (value !== null) args.push("--value", value);
  required(commandRunner, "python3", args, `P-22 AT-SPI ${suffix}`);
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
function defaultUI(commandRunner, options) {
  let app = null;
  return {
    async launch() {
      app = commandRunner.start(DESKTOP, [], { env: environment(options) });
      assert(
        Number.isSafeInteger(app.pid) && app.pid > 1,
        "P-22 desktop returned no PID",
      );
      await waitFor("P-22 installed desktop window", () => {
        const result = commandRunner.run("xdotool", [
          "search",
          "--onlyvisible",
          "--pid",
          String(app.pid),
          "--name",
          "^OpenBurnBar",
        ]);
        assert(result.status === 0, "installed Database window absent");
        return true;
      });
      atspi(
        commandRunner,
        options.rawOutputDir,
        "palette",
        "activate",
        "Open command palette",
      );
      atspi(
        commandRunner,
        options.rawOutputDir,
        "route",
        "activate",
        "Database",
      );
      await sleep(900);
      return { pid: app.pid };
    },
    snapshot(label) {
      return atspi(commandRunner, options.rawOutputDir, label, "snapshot");
    },
    async activate(name, label = "action") {
      const result = atspi(
        commandRunner,
        options.rawOutputDir,
        label,
        "activate",
        name,
      );
      await sleep(700);
      return result;
    },
    async setText(name, value, label = "text") {
      return atspi(
        commandRunner,
        options.rawOutputDir,
        label,
        "set-text",
        name,
        value,
      );
    },
    screenshot(name) {
      const file = path.join(options.rawOutputDir, name);
      required(
        commandRunner,
        "scrot",
        ["--overwrite", "--focused", file],
        `P-22 ${name}`,
      );
      assert(fs.statSync(file).size > 1024, `P-22 ${name} empty`);
      return file;
    },
    async stop() {
      if (!app) return;
      const pid = app.pid;
      app.kill();
      await waitFor(`P-22 desktop PID ${pid} exit`, () => {
        const result = commandRunner.run("kill", ["-0", String(pid)]);
        assert(result.status !== 0, "desktop still running");
        return true;
      });
      app = null;
    },
  };
}
function nextTime(clock) {
  const value = Math.max(Date.now(), clock.value + 1);
  clock.value = value;
  return new Date(value).toISOString();
}
function sanitizedRequest(method, request) {
  if (method === "daemon.database.recovery_bundle.export")
    return {
      destinationPath: request.destinationPath,
      passphraseRedacted: true,
    };
  if (method === "daemon.database.recovery_bundle.import")
    return { sourcePath: request.sourcePath, passphraseRedacted: true };
  return request ?? {};
}

export async function runP22NativeDatabaseProbes(options, dependencies = {}) {
  assert(
    (dependencies.platform ?? process.platform) === "linux",
    "P-22 native probe must execute on Linux",
  );
  assert(
    dependencies.desktopSession ??
      (process.env.DBUS_SESSION_BUS_ADDRESS && process.env.DISPLAY),
    "P-22 requires live X11 and D-Bus",
  );
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(options);
  options.rawOutputDir = privateDirectory(
    options.rawOutputDir,
    "P-22 raw output",
    { empty: true },
  );
  options.supportDir = privateDirectory(
    options.supportDir,
    "P-22 support directory",
  );
  options.homeDir = privateDirectory(options.homeDir, "P-22 isolated home", {
    empty: true,
  });
  const authToken = readToken(options.tokenFile);
  assert(
    path.dirname(fs.realpathSync(options.tokenFile)) === options.supportDir,
    "P-22 token must be inside support directory",
  );
  assert(
    JSON.stringify(fs.readdirSync(options.supportDir)) ===
      JSON.stringify([path.basename(options.tokenFile)]),
    "P-22 support directory must initially contain only its token",
  );
  assert(
    fs.realpathSync(path.dirname(options.indexDatabase)) ===
      options.supportDir && !fs.existsSync(options.indexDatabase),
    "P-22 index path is not isolated",
  );
  const commandRunner = dependencies.runner ?? runner();
  const processIDs = (
    dependencies.desktopProcessIDs ??
    (() => installedDesktopPids(commandRunner))
  )();
  assert(
    Array.isArray(processIDs) && processIDs.length === 0,
    "P-22 requires no pre-existing desktop",
  );
  if (!dependencies.ui)
    for (const command of ["python3", "xdotool", "scrot"])
      required(
        commandRunner,
        "sh",
        ["-c", 'command -v "$1" >/dev/null', "p22-tool", command],
        `required tool ${command}`,
      );

  const marker =
    dependencies.marker ?? `p22-${crypto.randomBytes(8).toString("hex")}`;
  const query = `P22IndexedMarker_${marker.replace(/-/gu, "_")}`;
  const watcherQuery = `P22WatcherMarker_${marker.replace(/-/gu, "_")}`;
  const projectDir = path.join(options.homeDir, `project-${marker}`);
  fs.mkdirSync(projectDir, { mode: 0o700 });
  const files = [];
  for (let index = 0; index < 14; index += 1) {
    const name = `record-${String(index).padStart(2, "0")}.ts`;
    writeExclusive(
      path.join(projectDir, name),
      Buffer.from(`export const P22IndexedSymbol${index} = "${query}";\n`),
    );
    files.push(name);
  }
  const snapshotPath = path.join(options.supportDir, `${marker}.snapshot`);
  const bundlePath = path.join(options.supportDir, `${marker}.recovery.obb`);
  const tamperedPath = path.join(options.supportDir, `${marker}.tampered.obb`);
  const passphrase =
    dependencies.passphrase ?? crypto.randomBytes(24).toString("base64url");
  const daemon =
    dependencies.daemon ?? daemonController(commandRunner, options);
  const rpc = dependencies.rpc ?? rpcClient(options, authToken);
  const ui = dependencies.ui ?? defaultUI(commandRunner, options);
  const clock = { value: 0 };
  const events = [];
  const uiEvents = [];
  let prepared = false;
  let app = null;
  const call = async (phase, method, request = {}) => {
    try {
      const result = await rpc(method, request);
      events.push({
        phase,
        at: nextTime(clock),
        method,
        request: sanitizedRequest(method, request),
        ok: true,
        error: null,
        result,
      });
      return result;
    } catch (error) {
      events.push({
        phase,
        at: nextTime(clock),
        method,
        request: sanitizedRequest(method, request),
        ok: false,
        error: error.message,
        result: null,
      });
      throw error;
    }
  };
  const reject = async (phase, method, request) => {
    try {
      await call(phase, method, request);
    } catch {
      return;
    }
    throw new Error(`P-22 expected ${phase} to fail closed`);
  };
  const observe = (phase, observed) =>
    uiEvents.push({
      phase,
      at: nextTime(clock),
      appPid: app.pid,
      marker,
      manifestSha256: options.manifestSha256,
      observed,
    });
  try {
    await daemon.prepare();
    prepared = true;
    const indexRequest = {
      projectPath: projectDir,
      maxFiles: 2500,
      maxFileBytes: 512000,
      storageBudgetBytes: null,
    };
    const indexed = await call(
      "index",
      "daemon.code.index_project",
      indexRequest,
    );
    assert(
      indexed.projectRoot === projectDir &&
        indexed.indexedFiles >= 14 &&
        indexed.chunkCount >= 14,
      "P-22 did not index the populated project",
    );
    const watched = await call("watch", "daemon.code.watch_project", {
      ...indexRequest,
      pollIntervalSeconds: 2,
    });
    assert(
      watched.watching === true && watched.projectRoot === projectDir,
      "P-22 watch did not start",
    );
    const searchRequest = { query, projectPath: projectDir, limit: 50 };
    const search = await call("search", "daemon.code.search", searchRequest);
    assert(
      search.hits?.length >= 11 &&
        search.trustSignal?.sourceTool === "daemon.code.search" &&
        search.trustSignal?.untrustedContentWrapped === true,
      "P-22 populated search did not return a paginated untrusted corpus",
    );
    const context = await call("context", "daemon.code.context_pack", {
      query,
      projectPath: projectDir,
      limit: 10,
      maxBytes: 24000,
    });
    assert(
      context.hits?.length > 0 &&
        context.context?.includes(query) &&
        context.trustSignal?.sourceTool === "daemon.code.context_pack" &&
        context.trustSignal?.untrustedContentWrapped === true,
      "P-22 context pack is invalid",
    );
    const explored = await call("explore", "daemon.code.explore", {
      projectPath: projectDir,
      query: null,
      limit: 50,
      maxBytes: 24000,
    });
    assert(
      explored.files?.some((file) => files.includes(file.filePath)),
      "P-22 explore omitted the populated indexed rows",
    );
    const status = await call("index-status", "daemon.code.index_status", {
      projectPath: projectDir,
    });
    assert(
      status.artifactCount >= 14 && status.databaseEncrypted === true,
      "P-22 index status is not populated and encrypted",
    );
    const recovery = await call(
      "recovery-ready",
      "daemon.database.recovery.status",
      {},
    );
    assert(
      recovery.phase === "ready" &&
        recovery.canExport === true &&
        recovery.databaseIntegrityVerified === true,
      `P-22 requires real SQLCipher/native-key readiness; daemon reported ${recovery.phase}:${recovery.code}`,
    );

    const snapshot = await call("snapshot", "daemon.code.database_snapshot", {
      destinationPath: snapshotPath,
      maxBytes: MAX_SNAPSHOT_BYTES,
    });
    assert(
      snapshot.databaseEncrypted === true &&
        snapshot.integrityCheck === "ok" &&
        snapshot.sha256 &&
        (fs.statSync(snapshotPath).mode & 0o077) === 0,
      "P-22 encrypted snapshot is invalid",
    );
    fs.appendFileSync(
      path.join(projectDir, files[0]),
      `export const watcher = "${watcherQuery}";\n`,
    );
    const restored = await call("restore", "daemon.code.database_restore", {
      snapshotPath,
      maxBytes: MAX_SNAPSHOT_BYTES,
    });
    assert(
      restored.databaseEncrypted === true &&
        restored.integrityCheck === "ok" &&
        restored.sha256 === snapshot.sha256,
      "P-22 restore did not verify the snapshot",
    );
    await sleep(3_000);
    const watcherSearch = await call(
      "watcher-reopen-search",
      "daemon.code.search",
      { query: watcherQuery, projectPath: projectDir, limit: 20 },
    );
    assert(
      watcherSearch.hits?.some((hit) => hit.snippet?.includes(watcherQuery)),
      "P-22 watcher did not reopen after restore",
    );

    const exported = await call(
      "bundle-export",
      "daemon.database.recovery_bundle.export",
      { destinationPath: bundlePath, passphrase },
    );
    assert(
      exported.byteCount > 0 &&
        exported.formatVersion === 1 &&
        (fs.statSync(bundlePath).mode & 0o077) === 0,
      "P-22 recovery bundle export is invalid",
    );
    await reject("wrong-passphrase", "daemon.database.recovery_bundle.import", {
      sourcePath: bundlePath,
      passphrase: `${passphrase}-wrong`,
    });
    const tampered = Buffer.from(fs.readFileSync(bundlePath));
    tampered[Math.floor(tampered.length / 2)] ^= 0xff;
    writeExclusive(tamperedPath, tampered);
    await reject("tampered-bundle", "daemon.database.recovery_bundle.import", {
      sourcePath: tamperedPath,
      passphrase,
    });
    const imported = await call(
      "bundle-import",
      "daemon.database.recovery_bundle.import",
      { sourcePath: bundlePath, passphrase },
    );
    assert(
      imported.stored === true &&
        imported.candidateKeyVerified === true &&
        imported.databaseIntegrityVerified === true &&
        imported.phase === "ready",
      "P-22 same-key recovery import was not verified",
    );
    await daemon.restart();
    const restartStatus = await call(
      "restart-recovery-status",
      "daemon.database.recovery.status",
      {},
    );
    assert(
      restartStatus.phase === "ready" &&
        restartStatus.databaseIntegrityVerified === true,
      "P-22 restart lost recovery readiness",
    );
    const restartSearch = await call(
      "restart-search",
      "daemon.code.search",
      searchRequest,
    );
    assert(
      restartSearch.hits?.length >= 11,
      "P-22 restart lost indexed corpus",
    );

    app = await ui.launch();
    await ui.activate("Atlas", "atlas");
    const atlasTree = ui.snapshot("atlas");
    const firstFile = files[0];
    const atlasObserved = {
      populated: includes(atlasTree, firstFile),
      indexedCorpus: includes(atlasTree, "Indexed corpus"),
      inspectAction: includes(atlasTree, `Inspect ${firstFile}`),
    };
    assert(
      Object.values(atlasObserved).every(Boolean),
      "P-22 Atlas did not expose populated rows",
    );
    observe("atlas", atlasObserved);
    ui.screenshot("database-atlas.png");
    await ui.activate(`Inspect ${firstFile}`, "inspect");
    const inspectorTree = ui.snapshot("inspector");
    const inspectorObserved = {
      inspector: includes(inspectorTree, "Record inspector"),
      path: includes(inspectorTree, firstFile),
      metadataOnly: includes(
        inspectorTree,
        "Source contents are not fetched or inferred",
      ),
    };
    assert(
      Object.values(inspectorObserved).every(Boolean),
      "P-22 metadata inspector is incomplete",
    );
    observe("inspector", inspectorObserved);
    ui.screenshot("database-inspector.png");
    await ui.setText("Query", query, "query");
    await ui.activate("Search code", "search-code");
    const searchTree = ui.snapshot("search");
    assert(
      includes(searchTree, "matching snippets") &&
        includes(searchTree, "Page 1 of"),
      "P-22 UI search did not populate",
    );
    await ui.activate("Next", "next-page");
    const pageTree = ui.snapshot("page-two");
    await ui.activate("Build context pack", "context-pack");
    const contextTree = ui.snapshot("context-pack");
    const retrievalObserved = {
      search: true,
      pageTwo: includes(pageTree, "Page 2 of"),
      contextPack: includes(contextTree, "Code context pack"),
      trustWarning: includes(contextTree, "Untrusted source data"),
    };
    assert(
      Object.values(retrievalObserved).every(Boolean),
      "P-22 retrieval UI is incomplete",
    );
    observe("retrieval", retrievalObserved);
    ui.screenshot("database-retrieval.png");
    await ui.activate("System", "system");
    await sleep(500);
    const systemTree = ui.snapshot("system");
    const systemObserved = {
      encrypted: includes(systemTree, "Sealed"),
      snapshot: includes(systemTree, "Encrypted snapshot & recovery"),
      recovery: includes(systemTree, "Recovery state: Ready"),
      indexControl: includes(systemTree, "Indexing control"),
    };
    assert(
      Object.values(systemObserved).every(Boolean),
      "P-22 System recovery UI is incomplete",
    );
    observe("system", systemObserved);
    ui.screenshot("database-system.png");
    await ui.stop();
    app = null;
    await daemon.restart();
    app = await ui.launch();
    await ui.activate("Atlas", "restart-atlas");
    const restartTree = ui.snapshot("restart");
    const restartObserved = {
      populated: includes(restartTree, firstFile),
      indexedCorpus: includes(restartTree, "Indexed corpus"),
    };
    assert(
      Object.values(restartObserved).every(Boolean),
      "P-22 UI restart lost indexed row",
    );
    observe("restart", restartObserved);
    ui.screenshot("database-restart.png");

    writeExclusive(
      path.join(options.rawOutputDir, "database-encrypted.snapshot"),
      fs.readFileSync(snapshotPath),
    );
    writeExclusive(
      path.join(options.rawOutputDir, "database-recovery.obb"),
      fs.readFileSync(bundlePath),
    );
    writeExclusive(
      path.join(options.rawOutputDir, "database-recovery-tampered.obb"),
      fs.readFileSync(tamperedPath),
    );
    writeJson(path.join(options.rawOutputDir, "database-marker.json"), {
      marker,
      projectDir,
      files,
      query,
      watcherQuery,
      snapshot: fileMetadata(snapshotPath),
      recoveryBundle: fileMetadata(bundlePath),
      tamperedBundle: fileMetadata(tamperedPath),
      recoveryLimits: {
        destructiveKeyLossNotInduced: true,
        deviceTransferNotInduced: true,
        reason:
          "The live proof does not delete or replace a user's native keyring state.",
      },
    });
    writeJson(
      path.join(options.rawOutputDir, "database-daemon-transcript.json"),
      {
        producer: "openburnbar-p22-installed-database-daemon-probe-v1",
        transport: "installed daemon AF_UNIX RPC",
        events,
      },
    );
    writeJson(path.join(options.rawOutputDir, "database-ui-transcript.json"), {
      producer: "openburnbar-p22-installed-database-ui-probe-v1",
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

export function parseP22Arguments(argv) {
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
      `${JSON.stringify(await runP22NativeDatabaseProbes(parseP22Arguments(process.argv.slice(2))), null, 2)}\n`,
    );
  } catch (error) {
    process.stderr.write(
      `P-22 native Database probe failed: ${error.message}\n`,
    );
    process.exitCode = 1;
  }
}
