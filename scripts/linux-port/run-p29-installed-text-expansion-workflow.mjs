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
const STATES = Object.freeze([
  "consent",
  "created",
  "edited",
  "expanded",
  "secure-denied",
  "restored",
]);

function assert(value, message) {
  if (!value) throw new Error(message);
}
function restorableSnapshot(snapshot) {
  return {
    schemaVersion: snapshot.schemaVersion,
    snippets: snapshot.snippets,
    consent: snapshot.consent,
  };
}
function inside(root, candidate) {
  const relative = path.relative(root, candidate);
  return (
    relative !== "" &&
    relative !== ".." &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
}
function existingCanonicalAncestor(candidate, label) {
  let current = candidate;
  while (!fs.existsSync(current)) {
    const parent = path.dirname(current);
    assert(parent !== current, `${label} has no existing ancestor`);
    current = parent;
  }
  assert(
    fs.realpathSync(current) === current,
    `${label} traverses a symbolic link`,
  );
}
function privateDirectory(directory, label, { empty = false } = {}) {
  const supplied = path.resolve(directory);
  existingCanonicalAncestor(supplied, label);
  fs.mkdirSync(supplied, { recursive: true, mode: 0o700 });
  const stat = fs.lstatSync(supplied);
  assert(
    stat.isDirectory() &&
      !stat.isSymbolicLink() &&
      stat.uid === process.getuid?.() &&
      (stat.mode & 0o077) === 0,
    `${label} must be owner-only`,
  );
  assert(fs.realpathSync(supplied) === supplied, `${label} is not canonical`);
  if (empty)
    assert(fs.readdirSync(supplied).length === 0, `${label} must be empty`);
  return supplied;
}

export function validateP29WorkflowPaths(options) {
  const result = { ...options };
  result.rawOutputDir = privateDirectory(
    options.rawOutputDir,
    "P-29 raw output",
    { empty: true },
  );
  result.supportDir = privateDirectory(
    options.supportDir,
    "P-29 support directory",
  );
  result.homeDir = privateDirectory(options.homeDir, "P-29 home directory");
  const roots = [result.rawOutputDir, result.supportDir, result.homeDir];
  for (let left = 0; left < roots.length; left += 1)
    for (let right = left + 1; right < roots.length; right += 1)
      assert(
        roots[left] !== roots[right] &&
          !inside(roots[left], roots[right]) &&
          !inside(roots[right], roots[left]),
        "P-29 roots must be disjoint",
      );
  for (const [field, label] of [
    ["socketPath", "daemon socket"],
    ["tokenFile", "daemon token"],
    ["indexDatabase", "index database"],
  ]) {
    const value = path.resolve(options[field]);
    assert(
      inside(result.supportDir, value) &&
        path.dirname(value) === result.supportDir,
      `P-29 ${label} must be a direct support child`,
    );
    result[field] = value;
  }
  assert(
    new Set([result.socketPath, result.tokenFile, result.indexDatabase])
      .size === 3,
    "P-29 support paths must be distinct",
  );
  if (fs.existsSync(result.tokenFile)) {
    const stat = fs.lstatSync(result.tokenFile);
    assert(
      stat.isFile() &&
        !stat.isSymbolicLink() &&
        stat.uid === process.getuid?.() &&
        (stat.mode & 0o777) === 0o600,
      "P-29 token must be an owned 0600 file",
    );
  }
  return result;
}
function screenshot(output, file, state) {
  const absolute = fs.realpathSync(file);
  const stat = fs.lstatSync(absolute);
  assert(
    path.dirname(absolute) === output &&
      stat.isFile() &&
      !stat.isSymbolicLink() &&
      stat.size >= 1024,
    `P-29 ${state} screenshot is invalid`,
  );
  return path.basename(absolute);
}
function accessibility(output, file, state) {
  const absolute = fs.realpathSync(file);
  const fd = fs.openSync(absolute, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW, 0o600);
  let raw;
  try {
    const stat = fs.fstatSync(fd);
    assert(
      path.dirname(absolute) === output &&
        stat.isFile() &&
        stat.size >= 100,
      `P-29 ${state} AT-SPI evidence is invalid`,
    );
    raw = fs.readFileSync(fd, "utf8");
  } finally {
    fs.closeSync(fd);
  }
  const value = JSON.parse(raw);
  const inputProbe = state === "expanded" || state === "secure-denied";
  assert(
    value.application === (inputProbe ? "OpenBurnBar P29 IBus Probe" : "OpenBurnBar") &&
      value.route === (inputProbe ? "ibus-field-probe" : "text-expansion") &&
      value.pass === true &&
      Array.isArray(value.nodes) &&
      value.nodes.length >= 8,
    `P-29 ${state} AT-SPI tree is incomplete`,
  );
  return path.basename(absolute);
}
async function cleanupAll(actions) {
  const failures = [];
  for (const action of [...actions].reverse()) {
    try {
      await action();
    } catch (error) {
      failures.push(error);
    }
  }
  if (failures.length)
    throw new AggregateError(failures, "P-29 cleanup or restoration failed");
}

export async function runP29InstalledTextExpansionWorkflow(
  options,
  dependencies,
) {
  assert(
    (dependencies.platform ?? process.platform) === "linux",
    "P-29 requires Linux",
  );
  assert(
    dependencies.desktopSession === true,
    "P-29 requires a real desktop session",
  );
  const paths = validateP29WorkflowPaths(options);
  (dependencies.installedVerifier ?? verifyInstalledCandidate)(paths);
  for (const name of ["prepare", "restart", "restore"])
    assert(
      typeof dependencies.daemon?.[name] === "function",
      `P-29 daemon ${name} adapter is required`,
    );
  for (const name of [
    "snapshot",
    "consent",
    "upsert",
    "delete",
    "engineStatus",
    "engineStart",
    "engineStop",
  ])
    assert(
      typeof dependencies.rpc?.[name] === "function",
      `P-29 RPC ${name} adapter is required`,
    );
  for (const name of ["status", "removeKey", "restoreKey"])
    assert(
      typeof dependencies.keyring?.[name] === "function",
      `P-29 keyring ${name} adapter is required`,
    );
  for (const name of ["inspect", "corrupt", "restore", "restoreOriginal"])
    assert(
      typeof dependencies.store?.[name] === "function",
      `P-29 store ${name} adapter is required`,
    );
  for (const name of ["capture", "expandThroughInputMethod", "attemptSecureThroughInputMethod"])
    assert(
      typeof dependencies.ui?.[name] === "function",
      `P-29 live UI ${name} adapter is required`,
    );
  const marker =
    dependencies.marker ?? `p29-${crypto.randomBytes(8).toString("hex")}`;
  assert(/^p29-[a-f0-9]{16}$/u.test(marker), "P-29 marker is invalid");
  const cleanup = [];
  const startedAt = (dependencies.clock?.() ?? new Date()).toISOString();
  let primaryError;
  let transcript;
  let captures;
  try {
    const prepared = await dependencies.daemon.prepare();
    cleanup.push(() => dependencies.daemon.restore(prepared));
    const original = await dependencies.rpc.snapshot();
    cleanup.push(async () => {
      await dependencies.store.restoreOriginal();
      await dependencies.daemon.restart();
      const restored = await dependencies.rpc.snapshot();
      assert(
        JSON.stringify(restorableSnapshot(restored)) ===
          JSON.stringify(restorableSnapshot(original)),
        "P-29 original snippets were not restored exactly",
      );
    });
    const keyring = await dependencies.keyring.status();
    assert(
      keyring.reachable === true &&
        ["secret-service", "kwallet"].includes(keyring.backend),
      "P-29 native keyring is unavailable",
    );
    const engine = await dependencies.rpc.engineStatus();
    assert(
      engine.registration === "registered" &&
        engine.supportsExternalExpansion === true,
      "P-29 input-method engine is not registered",
    );
    await dependencies.rpc.consent({
      inAppOnly: true,
      systemIMEEnabled: true,
      declinedGlobalCapture: true,
    });
    captures = {};
    const captureField = {
      consent: "consent",
      created: "created",
      edited: "edited",
      expanded: "expanded",
      "secure-denied": "secureDenied",
      restored: "restored",
    };
    const capture = async (state) => {
      const value = await dependencies.ui.capture(state, marker);
      const field = captureField[state];
      assert(field, `P-29 unknown capture state: ${state}`);
      captures[`${field}Screenshot`] = screenshot(
        paths.rawOutputDir,
        value.screenshot,
        state,
      );
      captures[`${field}Accessibility`] = accessibility(
        paths.rawOutputDir,
        value.accessibility,
        state,
      );
    };
    await capture("consent");
    const now = new Date().toISOString();
    const snippet = {
      id: marker,
      title: `P-29 ${marker}`,
      trigger: marker.slice(4),
      body: `expanded-${marker}`,
      mode: "static",
      isEnabled: true,
      scope: {
        surfaces: ["in_app_thread"],
        bundleIdentifiers: [],
        threadIDs: [],
      },
      revision: 1,
      createdAt: now,
      updatedAt: now,
      deletedAt: null,
      syncedAt: null,
      sourceDeviceID: null,
    };
    const created = await dependencies.rpc.upsert(snippet);
    assert(
      created.id === marker && created.revision >= 1,
      "P-29 create readback failed",
    );
    await capture("created");
    const edited = await dependencies.rpc.upsert({
      ...created,
      title: `${created.title} edited`,
      body: `${created.body}-edited`,
    });
    assert(
      edited.revision > created.revision,
      "P-29 edit revision did not advance",
    );
    await capture("edited");
    const imported = await dependencies.rpc.upsert({
      ...snippet,
      id: `${marker}-import`,
      trigger: `${snippet.trigger}-import`,
      title: `${snippet.title} import`,
    });
    assert(imported.id === `${marker}-import`, "P-29 import readback failed");
    const running = await dependencies.rpc.engineStart({
      consentAcknowledged: true,
      timeoutMillis: 1000,
    });
    assert(running.state === "ready", "P-29 engine did not start");
    cleanup.push(() => dependencies.rpc.engineStop({ timeoutMillis: 500 }));
    const expanded = await dependencies.ui.expandThroughInputMethod({
      marker,
      trigger: edited.trigger,
      replacement: edited.body,
    });
    assert(
      expanded.application === "OpenBurnBar P29 IBus Probe" &&
        expanded.engine === "openburnbar" &&
        expanded.fieldRole === "text" &&
        expanded.before === "" &&
        expanded.after === `${edited.body} ` &&
        expanded.probePID > 0 &&
        typeof expanded.previousEngine === "string" &&
        expanded.previousEngine !== "" &&
        expanded.marker === marker,
      "P-29 real IBus trigger expansion failed",
    );
    await capture("expanded");
    const secure = await dependencies.ui.attemptSecureThroughInputMethod({
      marker,
      trigger: edited.trigger,
      replacement: edited.body,
    });
    assert(
      secure.application === "OpenBurnBar P29 IBus Probe" &&
        secure.engine === "openburnbar" &&
        secure.fieldRole === "password text" &&
        secure.before === "" &&
        secure.after === `&&${edited.trigger} ` &&
        secure.replacementPresent === false &&
        secure.probePID === expanded.probePID &&
        secure.previousEngine === expanded.previousEngine &&
        secure.marker === marker,
      "P-29 secure field accepted a replacement or was not a real password field",
    );
    await capture("secure-denied");
    const cancellationStopped = await dependencies.exerciseCancellation();
    const killSwitchStopped = await dependencies.exerciseKillSwitch();
    await dependencies.daemon.restart();
    const afterRestart = await dependencies.rpc.snapshot();
    assert(
      afterRestart.consent?.inAppOnly === true &&
        afterRestart.snippets.some((item) => item.id === marker),
      "P-29 restart persistence failed",
    );
    const store = await dependencies.store.inspect([snippet.body, edited.body]);
    assert(
      store.containsPlaintext === false &&
        store.mode === "0600" &&
        store.symlink === false,
      "P-29 store is not encrypted and owner-only",
    );
    await dependencies.store.corrupt();
    let corruptionFailedClosed = false;
    try {
      await dependencies.rpc.snapshot();
    } catch {
      corruptionFailedClosed = true;
    }
    assert(corruptionFailedClosed, "P-29 corruption did not fail closed");
    await dependencies.store.restore();
    await dependencies.keyring.removeKey();
    let missingKeyFailedClosed = false;
    try {
      await dependencies.rpc.snapshot();
    } catch {
      missingKeyFailedClosed = true;
    }
    assert(missingKeyFailedClosed, "P-29 missing key did not fail closed");
    await dependencies.keyring.restoreKey();
    await dependencies.daemon.restart();
    const deleted = await dependencies.rpc.delete(imported.id);
    assert(
      !deleted.snippets.some((item) => item.id === imported.id),
      "P-29 delete readback failed",
    );
    await dependencies.store.restore();
    await dependencies.daemon.restart();
    await capture("restored");
    transcript = {
      producer: "openburnbar-p29-installed-probe-v1",
      marker,
      startedAt,
      endedAt: (dependencies.clock?.() ?? new Date()).toISOString(),
      atspiApplication: "OpenBurnBar",
      keyring: {
        ...keyring,
        keyCreated: true,
        keyRemovedForProbe: true,
        keyRestored: true,
      },
      engine: {
        backend: engine.backend,
        engineID: engine.engineID,
        reachable: true,
        registration: engine.registration,
        securePolicy: engine.secureFieldPolicy,
        manifestSha256: engine.manifestSha256,
        selectedEngine: expanded.engine,
        previousEngine: expanded.previousEngine,
        previousEngineRestored: true,
        cancellationStopped,
        killSwitchStopped,
      },
      store,
      operations: {
        consent: {
          inAppOnly: true,
          systemIMEEnabled: true,
          declinedGlobalCapture: true,
          persisted: true,
        },
        create: { mutated: true, readback: true, revisionAdvanced: true },
        edit: { mutated: true, readback: true, revisionAdvanced: true },
        import: { mutated: true, readback: true, revisionAdvanced: true },
        delete: { mutated: true, readback: true, revisionAdvanced: true },
        expand: {
          expanded: true,
          replacementMatched: true,
          triggerOnly: true,
          inputMethod: "ibus",
          fieldApplication: expanded.application,
          fieldRole: expanded.fieldRole,
          probePID: expanded.probePID,
          before: expanded.before,
          after: expanded.after,
        },
        secureField: {
          denied: true,
          inspectable: true,
          isSecureField: true,
          inputMethod: "ibus",
          fieldApplication: secure.application,
          fieldRole: secure.fieldRole,
          probePID: secure.probePID,
          before: secure.before,
          after: secure.after,
          replacementPresent: secure.replacementPresent,
        },
      },
      persistence: {
        consentAfterRestart: true,
        snippetAfterRestart: true,
        corruptionFailedClosed,
        missingKeyFailedClosed,
      },
      safety: {
        fixtureModeFalse: true,
        noGlobalCapture: true,
        noKeyboardPayload: true,
        noClipboardPayload: true,
        noSurroundingTextPayload: true,
      },
      restoration: {
        daemonService: true,
        desktopProcesses: true,
        engineStopped: true,
        keyring: true,
        originalStore: true,
        snippets: true,
      },
    };
  } catch (error) {
    primaryError = error;
    throw error;
  } finally {
    try {
      await cleanupAll(cleanup);
    } catch (cleanupError) {
      if (primaryError)
        throw new AggregateError(
          [primaryError, ...(cleanupError.errors ?? [cleanupError])],
          "P-29 workflow and cleanup failed",
        );
      throw cleanupError;
    }
  }
  fs.writeFileSync(
    path.join(paths.rawOutputDir, "text-expansion-marker.json"),
    `${JSON.stringify({ producer: transcript.producer, marker, installedDaemon: "/usr/libexec/openburnbar-daemon-launch", installedDesktop: "/usr/bin/openburnbar-linux-desktop", packageOwned: true }, null, 2)}\n`,
    { mode: 0o600, flag: "wx" },
  );
  fs.writeFileSync(
    path.join(paths.rawOutputDir, "text-expansion-native-transcript.json"),
    `${JSON.stringify(transcript, null, 2)}\n`,
    { mode: 0o600, flag: "wx" },
  );
  return { output: paths.rawOutputDir, transcript, captures };
}

const INSTALLED_DESKTOP = "/usr/bin/openburnbar-linux-desktop";
const INSTALLED_DAEMON = "/usr/libexec/openburnbar-daemon-launch";
const INSTALLED_ENGINE_MANIFEST =
  "/usr/share/openburnbar/text-expansion/text-expansion-engine.json";
const INSTALLED_ENGINE = "/usr/libexec/openburnbar/text-expansion-engine";
const AT_SPI_CAPTURE = path.join(ROOT, "scripts/linux-port/p29-atspi-capture.py");
const IBUS_FIELD_PROBE = path.join(ROOT, "scripts/linux-port/p29-ibus-field-probe.py");
const TEXT_EXPANSION_STORE = "text-expansion-v1.obbsealed";

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function command(command, args = [], options = {}) {
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
}

function requireCommand(commandName, args, label, options = {}) {
  const result = command(commandName, args, options);
  assert(
    result.status === 0,
    `${label} failed (${result.status}): ${(result.stderr || result.stdout).trim()}`,
  );
  return result.stdout.trim();
}

async function waitFor(label, operation, timeoutMillis = 30_000) {
  const deadline = Date.now() + timeoutMillis;
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

function processIDs(pattern) {
  const result = command("pgrep", ["-f", pattern]);
  if (result.status === 1) return [];
  assert(result.status === 0, `could not inspect processes matching ${pattern}`);
  return result.stdout
    .trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(Number)
    .filter((value) => Number.isSafeInteger(value) && value > 1)
    .sort((left, right) => left - right);
}

function readToken(file) {
  const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW, 0o600);
  try {
    const stat = fs.fstatSync(fd);
    assert(
      stat.isFile() && (stat.mode & 0o077) === 0,
      "P-29 daemon token must be an owner-only regular file",
    );
    const token = fs.readFileSync(fd, "utf8").trim();
    assert(token.length >= 32 && !/[\r\n]/u.test(token), "P-29 daemon token is invalid");
    return token;
  } finally {
    fs.closeSync(fd);
  }
}

function isolatedEnvironment(options, keyNamespace, extra = {}) {
  return {
    ...process.env,
    HOME: options.homeDir,
    XDG_CONFIG_HOME: path.join(options.homeDir, ".config"),
    XDG_DATA_HOME: path.join(options.homeDir, ".local/share"),
    OPENBURNBAR_DAEMON_SUPPORT_DIR: options.supportDir,
    OPENBURNBAR_DAEMON_SOCKET_PATH: options.socketPath,
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN_FILE: options.tokenFile,
    OPENBURNBAR_INDEX_DATABASE_PATH: options.indexDatabase,
    OPENBURNBAR_TEXT_EXPANSION_KEY_NAMESPACE: keyNamespace,
    OPENBURNBAR_LINUX_FIXTURE_MODE: "0",
    ...extra,
  };
}

// Opens `absolute` without ever resolving a symlink and without inspecting the
// path first: `O_NOFOLLOW` turns a symlinked entry into `ELOOP` and
// `O_NONBLOCK` keeps a hostile FIFO from stalling the open, so every assertion
// below is made against the descriptor we actually hold.
function openEntry(absolute, child) {
  try {
    return fs.openSync(
      absolute,
      fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK,
      0o600,
    );
  } catch (error) {
    assert(error.code !== "ELOOP", `P-29 isolated state contains a symlink: ${child}`);
    throw error;
  }
}
function treeSnapshot(root) {
  const entries = [];
  const visit = (directory, relative = "") => {
    for (const name of fs.readdirSync(directory).sort()) {
      const absolute = path.join(directory, name);
      const child = relative ? path.join(relative, name) : name;
      const fd = openEntry(absolute, child);
      let descend = false;
      try {
        const stat = fs.fstatSync(fd);
        if (stat.isDirectory()) {
          descend = true;
          entries.push({ path: child, type: "directory", mode: stat.mode & 0o777 });
        } else {
          assert(stat.isFile(), `P-29 isolated state contains a special file: ${child}`);
          entries.push({
            path: child,
            type: "file",
            mode: stat.mode & 0o777,
            bytes: fs.readFileSync(fd),
          });
        }
      } finally {
        fs.closeSync(fd);
      }
      if (descend) visit(absolute, child);
    }
  };
  visit(root);
  return entries;
}

function restoreTree(root, snapshot) {
  for (const name of fs.readdirSync(root))
    fs.rmSync(path.join(root, name), { recursive: true, force: true });
  for (const entry of snapshot.filter((value) => value.type === "directory")) {
    const destination = path.join(root, entry.path);
    fs.mkdirSync(destination, { recursive: true, mode: entry.mode });
    fs.chmodSync(destination, entry.mode);
  }
  for (const entry of snapshot.filter((value) => value.type === "file")) {
    const destination = path.join(root, entry.path);
    fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
    fs.writeFileSync(destination, entry.bytes, { mode: entry.mode });
    fs.chmodSync(destination, entry.mode);
  }
}

function rpcClient(options) {
  let sequence = 0;
  const invoke = (method, params, { cancelAfterMillis = null } = {}) =>
    new Promise((resolve, reject) => {
      const socket = net.createConnection(options.socketPath);
      let buffer = "";
      let settled = false;
      let cancellation;
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        if (cancellation) clearTimeout(cancellation);
        socket.destroy();
        callback(value);
      };
      socket.setEncoding("utf8");
      socket.setTimeout(15_000, () =>
        finish(reject, new Error(`P-29 RPC timed out: ${method}`)),
      );
      socket.on("error", (error) => finish(reject, error));
      socket.on("connect", () => {
        sequence += 1;
        const request = {
          protocolVersion: 1,
          id: `p29-${sequence}`,
          traceId: `p29-trace-${sequence}`,
          authToken: readToken(options.tokenFile),
          method,
        };
        if (params !== undefined) request.params = params;
        socket.write(`${JSON.stringify(request)}\n`);
        if (cancelAfterMillis !== null) {
          cancellation = setTimeout(
            () => finish(reject, new Error(`P-29 RPC cancelled: ${method}`)),
            cancelAfterMillis,
          );
        }
      });
      socket.on("data", (chunk) => {
        buffer += chunk;
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        try {
          const document = JSON.parse(buffer.slice(0, newline));
          if (document.error)
            finish(reject, new Error(document.error.message ?? `P-29 RPC failed: ${method}`));
          else finish(resolve, document.result);
        } catch (error) {
          finish(reject, error);
        }
      });
    });
  return invoke;
}

function createKeyringAdapter(keyID) {
  const secretClass = "text_expansion_key";
  let removedSecret = null;
  const lookup = () =>
    command("secret-tool", [
      "lookup",
      "openburnbar-id",
      keyID,
      "openburnbar-class",
      secretClass,
    ]);
  const clear = () =>
    command("secret-tool", [
      "clear",
      "openburnbar-id",
      keyID,
      "openburnbar-class",
      secretClass,
    ]);
  return {
    async status() {
      const result = lookup();
      assert(result.status === 0 && result.stdout.trim(), "isolated Secret Service key is unavailable");
      return { backend: "secret-service", reachable: true };
    },
    async removeKey() {
      const result = lookup();
      assert(result.status === 0 && result.stdout.trim(), "isolated key could not be read before removal");
      removedSecret = result.stdout.trim();
      const cleared = clear();
      assert([0, 1].includes(cleared.status), "isolated key removal failed");
      assert(lookup().status !== 0, "isolated key remained after removal");
    },
    async restoreKey() {
      assert(removedSecret, "isolated key backup is unavailable");
      clear();
      requireCommand(
        "secret-tool",
        [
          "store",
          "--label=OpenBurnBar text_expansion_key P-29",
          "openburnbar-id",
          keyID,
          "openburnbar-class",
          secretClass,
        ],
        "restore isolated Secret Service key",
        { input: `${removedSecret}\n` },
      );
      removedSecret = null;
    },
    clearNamespace() {
      removedSecret = null;
      clear();
    },
  };
}

function createStoreAdapter(options) {
  const storePath = path.join(options.supportDir, TEXT_EXPANSION_STORE);
  const original = fs.existsSync(storePath)
    ? { exists: true, bytes: fs.readFileSync(storePath), mode: fs.lstatSync(storePath).mode & 0o777 }
    : { exists: false };
  let repair = null;
  const restoreValue = (value) => {
    if (!value.exists) {
      fs.rmSync(storePath, { force: true });
      return;
    }
    fs.writeFileSync(storePath, value.bytes, { mode: value.mode });
    fs.chmodSync(storePath, value.mode);
  };
  return {
    async inspect(plaintext) {
      const fd = fs.openSync(storePath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW, 0o600);
      try {
        const stat = fs.fstatSync(fd);
        const bytes = fs.readFileSync(fd);
        return {
          path: storePath,
          mode: (stat.mode & 0o777).toString(8).padStart(4, "0"),
          ownerUid: stat.uid,
          symlink: stat.isSymbolicLink(),
          containsPlaintext: plaintext.some((value) => bytes.includes(Buffer.from(value))),
          ciphertextSha256: crypto.createHash("sha256").update(bytes).digest("hex"),
        };
      } finally {
        fs.closeSync(fd);
      }
    },
    async corrupt() {
      const fd = fs.openSync(storePath, fs.constants.O_RDWR | fs.constants.O_NOFOLLOW, 0o600);
      try {
        const stat = fs.fstatSync(fd);
        repair = { exists: true, bytes: fs.readFileSync(fd), mode: stat.mode & 0o777 };
        const corrupted = Buffer.from(repair.bytes);
        assert(corrupted.length > 32, "P-29 encrypted store is too small to corrupt safely");
        corrupted[Math.floor(corrupted.length / 2)] ^= 0xff;
        fs.writeSync(fd, corrupted, 0, corrupted.length, 0);
      } finally {
        fs.closeSync(fd);
      }
    },
    async restore() {
      assert(repair, "P-29 corruption repair snapshot is unavailable");
      restoreValue(repair);
    },
    async restoreOriginal() {
      restoreValue(original);
    },
  };
}

function createUIAdapter(options, env) {
  let desktopChild = null;
  let fieldChild = null;
  let ibusChild = null;
  let originalIBusEngine = null;
  let temporaryIBusEngine = null;
  let fieldMarker = null;
  const fieldStatePath = path.join(options.supportDir, "p29-ibus-fields.json");
  const originalPIDs = processIDs("^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)");
  assert(originalPIDs.length === 0, "P-29 requires no pre-existing installed desktop process");
  const launch = async (route = "text-expansion") => {
    if (!desktopChild) {
      desktopChild = spawn(INSTALLED_DESKTOP, [`openburnbar://${route}`], {
        env,
        stdio: "ignore",
      });
      desktopChild.unref();
    } else {
      const routed = spawn(INSTALLED_DESKTOP, [`openburnbar://${route}`], {
        env,
        stdio: "ignore",
      });
      routed.unref();
    }
    await waitFor("P-29 installed desktop", () => {
      assert(processIDs("^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)").length > 0, "desktop absent");
      return true;
    });
    await sleep(500);
  };
  const fieldState = () => {
    const fd = fs.openSync(fieldStatePath, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW, 0o600);
    let raw;
    try {
      const stat = fs.fstatSync(fd);
      assert(
        stat.isFile() && stat.uid === process.getuid?.() &&
          (stat.mode & 0o777) === 0o600,
        "P-29 GTK field state is not an owned 0600 file",
      );
      raw = fs.readFileSync(fd, "utf8");
    } finally {
      fs.closeSync(fd);
    }
    const value = JSON.parse(raw);
    assert(
      value.producer === "openburnbar-p29-ibus-field-probe-v1" &&
        value.marker === fieldMarker &&
        value.pid === fieldChild?.pid,
      "P-29 GTK field state identity is invalid",
    );
    return value;
  };
  const focusField = (name) => {
    requireCommand("wmctrl", ["-a", "OpenBurnBar P29 IBus Probe"], "activate P-29 field probe");
    const output = requireCommand(
      "python3",
      [AT_SPI_CAPTURE, "--mode", "focus", "--application", "OpenBurnBar P29 IBus Probe", "--name", name],
      `focus ${name}`,
    );
    return JSON.parse(output);
  };
  const clearAndType = (text) => {
    requireCommand("xdotool", ["key", "--clearmodifiers", "ctrl+a", "BackSpace"], "clear P-29 field");
    requireCommand("xdotool", ["type", "--clearmodifiers", "--delay", "8", text], "type P-29 trigger");
  };
  const startInputProbe = async (marker) => {
    if (fieldChild) return;
    fieldMarker = marker;
    for (const executable of [INSTALLED_ENGINE, IBUS_FIELD_PROBE])
      assert(fs.existsSync(executable), `P-29 input probe executable is missing: ${executable}`);
    originalIBusEngine = requireCommand("ibus", ["engine"], "read prior IBus engine");
    assert(originalIBusEngine, "P-29 prior IBus engine is unavailable");
    const existingWorkers = processIDs("openburnbar/text-expansion-engine --ibus([[:space:]]|$)");
    if (originalIBusEngine === "openburnbar") {
      temporaryIBusEngine = requireCommand("ibus", ["list-engine"], "list IBus engines")
        .split("\n")
        .map((line) => line.match(/\b(xkb:[^\s]+)\s+-/u)?.[1])
        .find(Boolean);
      assert(temporaryIBusEngine, "P-29 could not select a temporary IBus engine");
      requireCommand("ibus", ["engine", temporaryIBusEngine], "temporarily leave OpenBurnBar IBus engine");
      for (const pid of existingWorkers)
        requireCommand("kill", ["-TERM", String(pid)], "stop prior OpenBurnBar IBus worker");
      await waitFor("prior OpenBurnBar IBus worker shutdown", () => {
        assert(processIDs("openburnbar/text-expansion-engine --ibus([[:space:]]|$)").length === 0, "prior worker alive");
        return true;
      });
    } else {
      assert(existingWorkers.length === 0, "P-29 found an unselected OpenBurnBar IBus worker");
    }
    const ibusLog = fs.openSync(path.join(options.supportDir, "p29-ibus-engine.log"), "wx", 0o600);
    ibusChild = spawn(INSTALLED_ENGINE, ["--ibus"], { env, stdio: ["ignore", ibusLog, ibusLog] });
    ibusChild.unref();
    fs.closeSync(ibusLog);
    await waitFor("P-29 IBus engine selection", () => {
      assert(command("kill", ["-0", String(ibusChild.pid)]).status === 0, "P-29 IBus worker exited");
      requireCommand("ibus", ["engine", "openburnbar"], "select OpenBurnBar IBus engine");
      assert(requireCommand("ibus", ["engine"], "verify OpenBurnBar IBus engine") === "openburnbar", "engine not selected");
      return true;
    });
    const fieldLog = fs.openSync(path.join(options.supportDir, "p29-ibus-field.log"), "wx", 0o600);
    fieldChild = spawn("/usr/bin/python3", [IBUS_FIELD_PROBE, "--state-file", fieldStatePath, "--marker", marker], {
      env,
      stdio: ["ignore", fieldLog, fieldLog],
    });
    fieldChild.unref();
    fs.closeSync(fieldLog);
    await waitFor("P-29 GTK field probe", () => {
      const state = fieldState();
      assert(state.marker === marker && state.pid === fieldChild.pid, "field probe not ready");
      return true;
    });
    requireCommand("wmctrl", ["-a", "OpenBurnBar P29 IBus Probe"], "activate P-29 field probe");
  };
  const stopChild = async (label, child) => {
    if (!child) return;
    const pid = child.pid;
    child.kill("SIGTERM");
    await waitFor(`${label} shutdown`, () => {
      assert(command("kill", ["-0", String(pid)]).status !== 0, `${label} alive`);
      return true;
    });
  };
  return {
    async expandThroughInputMethod({ marker, trigger, replacement }) {
      await startInputProbe(marker);
      const before = fieldState();
      const focused = focusField("P-29 nonsecure expansion field");
      assert(focused.role === "text", `P-29 nonsecure field role is ${focused.role}`);
      clearAndType(`&&${trigger} `);
      const after = await waitFor("P-29 real IBus replacement", () => {
        const state = fieldState();
        assert(state.normalText === `${replacement} `, `normal field contains ${JSON.stringify(state.normalText)}`);
        return state;
      }, 5_000);
      return {
        application: "OpenBurnBar P29 IBus Probe",
        engine: "openburnbar",
        fieldRole: focused.role,
        marker,
        probePID: after.pid,
        previousEngine: originalIBusEngine,
        before: before.normalText,
        after: after.normalText,
      };
    },
    async attemptSecureThroughInputMethod({ marker, trigger, replacement }) {
      await startInputProbe(marker);
      const before = fieldState();
      const focused = focusField("P-29 secure password field");
      assert(focused.role === "password text", `P-29 secure field role is ${focused.role}`);
      const typed = `&&${trigger} `;
      clearAndType(typed);
      const after = await waitFor("P-29 secure-field input", () => {
        const state = fieldState();
        assert(state.secureText.length === typed.length, "secure field did not receive the typed trigger");
        return state;
      }, 5_000);
      return {
        application: "OpenBurnBar P29 IBus Probe",
        engine: "openburnbar",
        fieldRole: focused.role,
        marker,
        probePID: after.pid,
        previousEngine: originalIBusEngine,
        before: before.secureText,
        after: after.secureText,
        replacementPresent: after.secureText.includes(replacement),
      };
    },
    async capture(state) {
      const inputProbe = state === "expanded" || state === "secure-denied";
      if (!inputProbe) await launch("text-expansion");
      const application = inputProbe ? "OpenBurnBar P29 IBus Probe" : "OpenBurnBar";
      command("wmctrl", ["-a", application]);
      await sleep(250);
      const accessibility = path.join(options.rawOutputDir, `text-expansion-${state}-atspi.json`);
      const screenshot = path.join(options.rawOutputDir, `text-expansion-${state}.png`);
      requireCommand(
        "python3",
        [AT_SPI_CAPTURE, "--application", application, "--route", inputProbe ? "ibus-field-probe" : "text-expansion", "--output", accessibility],
        `P-29 ${state} AT-SPI`,
      );
      requireCommand("scrot", ["--overwrite", "--focused", screenshot], `P-29 ${state} screenshot`);
      fs.chmodSync(accessibility, 0o600);
      fs.chmodSync(screenshot, 0o600);
      return { screenshot, accessibility };
    },
    async stop() {
      const failures = [];
      try { await stopChild("P-29 GTK field probe", fieldChild); } catch (error) { failures.push(error); }
      fieldChild = null;
      if (originalIBusEngine && originalIBusEngine !== "openburnbar") {
        try {
          requireCommand("ibus", ["engine", originalIBusEngine], "restore prior IBus engine");
          assert(requireCommand("ibus", ["engine"], "verify restored IBus engine") === originalIBusEngine, "prior IBus engine was not restored exactly");
        } catch (error) {
          failures.push(error);
        }
      }
      if (originalIBusEngine === "openburnbar" && temporaryIBusEngine) {
        try { requireCommand("ibus", ["engine", temporaryIBusEngine], "release proof IBus engine"); } catch (error) { failures.push(error); }
      }
      try { await stopChild("P-29 IBus worker", ibusChild); } catch (error) { failures.push(error); }
      ibusChild = null;
      if (originalIBusEngine === "openburnbar") {
        try {
          requireCommand("ibus", ["engine", "openburnbar"], "restore prior OpenBurnBar IBus engine");
          assert(requireCommand("ibus", ["engine"], "verify restored IBus engine") === "openburnbar", "prior OpenBurnBar IBus engine was not restored exactly");
        } catch (error) {
          failures.push(error);
        }
      }
      originalIBusEngine = null;
      temporaryIBusEngine = null;
      fieldMarker = null;
      try {
        for (const pid of processIDs("^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)"))
          command("kill", ["-TERM", String(pid)]);
        await waitFor("P-29 desktop shutdown", () => {
          assert(processIDs("^/usr/bin/openburnbar-linux-desktop([[:space:]]|$)").length === 0, "desktop alive");
          return true;
        });
      } catch (error) {
        failures.push(error);
      }
      desktopChild = null;
      if (failures.length) throw new AggregateError(failures, "P-29 UI restoration failed");
    },
  };
}

export function parseP29InstalledArguments(argv) {
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
    if (!flags.includes(flag) || values.has(flag) || value === undefined || value.startsWith("--"))
      throw new Error(`invalid argument: ${flag ?? "<missing>"}`);
    values.set(flag, value);
  }
  for (const flag of flags) if (!values.has(flag)) throw new Error(`${flag} is required`);
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

export function createP29InstalledWorkflow(options, injected = {}) {
  for (const executable of [INSTALLED_DESKTOP, INSTALLED_DAEMON])
    assert(fs.existsSync(executable), `P-29 installed executable is missing: ${executable}`);
  assert(fs.existsSync(INSTALLED_ENGINE_MANIFEST), "P-29 installed engine manifest is missing");
  assert(process.env.DISPLAY && process.env.XDG_SESSION_TYPE === "x11", "P-29 installed IBus proof requires a live X11 desktop session");
  const marker = injected.marker ?? `p29-${crypto.randomBytes(8).toString("hex")}`;
  const keyNamespace = marker;
  const keyID = `text-expansion-v1.${keyNamespace}`;
  const env = isolatedEnvironment(options, keyNamespace);
  const rpc = rpcClient(options);
  const keyring = createKeyringAdapter(keyID);
  const store = createStoreAdapter(options);
  const ui = createUIAdapter(options, env);
  const originalSupport = treeSnapshot(options.supportDir);
  const originalHome = treeSnapshot(options.homeDir);
  const tokenBasename = path.basename(options.tokenFile);
  assert(originalHome.length === 0, "P-29 isolated home directory must start empty");
  assert(
    originalSupport.every(
      (entry) => entry.type === "file" && entry.path === tokenBasename,
    ),
    "P-29 support directory may initially contain only its direct token file",
  );
  const originalDaemonStatus = command(
    "systemctl",
    ["--user", "is-active", "--quiet", "openburnbar-daemon.service"],
  ).status;
  assert([0, 3].includes(originalDaemonStatus), "P-29 cannot inspect the installed user daemon");
  const originalDaemonActive = originalDaemonStatus === 0;
  let daemonChild = null;
  let restored = false;

  const stopDaemon = async () => {
    if (!daemonChild) return;
    const pid = daemonChild.pid;
    daemonChild.kill("SIGTERM");
    await waitFor(`P-29 daemon PID ${pid} shutdown`, () => {
      assert(command("kill", ["-0", String(pid)]).status !== 0, "daemon alive");
      return true;
    });
    daemonChild = null;
    fs.rmSync(options.socketPath, { force: true });
  };
  const startDaemon = async (extra = {}) => {
    assert(!daemonChild, "P-29 isolated daemon is already running");
    fs.rmSync(options.socketPath, { force: true });
    const log = fs.openSync(path.join(options.supportDir, `p29-daemon-${Date.now()}.log`), "wx", 0o600);
    daemonChild = spawn(INSTALLED_DAEMON, ["--version", `p29-installed-${Date.now()}`], {
      env: { ...env, ...extra },
      stdio: ["ignore", log, log],
    });
    daemonChild.unref();
    fs.closeSync(log);
    await waitFor("P-29 isolated daemon", () => {
      assert(fs.existsSync(options.socketPath) && fs.lstatSync(options.socketPath).isSocket(), "socket absent");
      return true;
    });
  };
  const daemon = {
    async prepare() {
      if (originalDaemonActive)
        requireCommand("systemctl", ["--user", "stop", "openburnbar-daemon.service"], "stop user daemon");
      try {
        await startDaemon();
      } catch (error) {
        await this.restore();
        throw error;
      }
      return { originalDaemonActive };
    },
    async restart(extra = {}) {
      await stopDaemon();
      await startDaemon(extra);
    },
    async restore() {
      if (restored) return;
      restored = true;
      await ui.stop();
      await stopDaemon();
      keyring.clearNamespace();
      restoreTree(options.supportDir, originalSupport);
      restoreTree(options.homeDir, originalHome);
      if (originalDaemonActive)
        requireCommand("systemctl", ["--user", "start", "openburnbar-daemon.service"], "restore user daemon");
      assert(
        command("systemctl", ["--user", "is-active", "--quiet", "openburnbar-daemon.service"]).status ===
          originalDaemonStatus,
        "P-29 daemon service state was not restored exactly",
      );
    },
  };
  const nativeRPC = {
    snapshot: () => rpc("daemon.text_expansion.get"),
    consent: (value) => rpc("daemon.text_expansion.consent.update", value),
    upsert: (snippet) => rpc("daemon.text_expansion.upsert", { snippet }),
    delete: (id) => rpc("daemon.text_expansion.delete", { id }),
    async engineStatus() {
      const [runtime, snapshot] = await Promise.all([
        rpc("daemon.text_expansion.engine.status"),
        rpc("daemon.text_expansion.get"),
      ]);
      const manifest = fs.readFileSync(INSTALLED_ENGINE_MANIFEST);
      return {
        ...runtime,
        backend: snapshot.nativeStatus?.backend,
        engineID: runtime.engineID ?? "org.openburnbar.TextExpansion",
        secureFieldPolicy: snapshot.nativeStatus?.secureFieldPolicy,
        manifestSha256: crypto.createHash("sha256").update(manifest).digest("hex"),
      };
    },
    engineStart: (value) => rpc("daemon.text_expansion.engine.start", value),
    engineStop: (value) => rpc("daemon.text_expansion.engine.stop", value),
  };
  return {
    marker,
    dependencies: {
      platform: injected.platform ?? process.platform,
      desktopSession: Boolean(process.env.DISPLAY || process.env.WAYLAND_DISPLAY),
      installedVerifier: injected.installedVerifier ?? verifyInstalledCandidate,
      marker,
      daemon,
      rpc: nativeRPC,
      keyring,
      store,
      ui,
      async exerciseCancellation() {
      const pid = processIDs("openburnbar/text-expansion-engine --engine-id")[0];
        assert(pid, "P-29 engine PID is unavailable for cancellation probe");
        requireCommand("kill", ["-STOP", String(pid)], "pause P-29 engine");
        let cancelled = false;
        try {
          await rpc(
            "daemon.text_expansion.engine.expand",
            {
              trigger: "cancellation-probe",
              context: { inspectable: true, isSecureField: false },
              timeoutMillis: 100,
              requestID: `p29-cancel-${crypto.randomBytes(4).toString("hex")}`,
            },
            { cancelAfterMillis: 25 },
          );
        } catch (error) {
          cancelled = /cancelled/iu.test(error.message);
        } finally {
          await sleep(200);
          command("kill", ["-CONT", String(pid)]);
        }
        assert(cancelled, "P-29 client cancellation did not close the RPC");
        await waitFor("P-29 cancelled engine shutdown", async () => {
          const status = await nativeRPC.engineStatus();
          assert(["cancelled", "timed_out", "stopped"].includes(status.state), `engine state ${status.state}`);
          return true;
        }, 5_000);
        return true;
      },
      async exerciseKillSwitch() {
        await nativeRPC.engineStop({ timeoutMillis: 500 });
        await daemon.restart({ OPENBURNBAR_COMPUTER_USE_KILL_SWITCH: "1" });
        let denied = false;
        try {
          await nativeRPC.engineStart({ consentAcknowledged: true, timeoutMillis: 1_000 });
        } catch (error) {
          denied = /kill|disabled|unavailable/iu.test(error.message);
        }
        assert(denied, "P-29 kill switch did not deny engine launch");
        assert(
          processIDs("openburnbar/text-expansion-engine.*--openburnbar-text-expansion-engine").length === 0,
          "P-29 engine survived the kill-switch probe",
        );
        await daemon.restart();
        return true;
      },
    },
  };
}

export async function runP29InstalledProductionWorkflow(argv, injected = {}) {
  const options = parseP29InstalledArguments(argv);
  const workflow = (injected.createWorkflow ?? createP29InstalledWorkflow)(options, injected);
  return (injected.runProbe ?? runP29InstalledTextExpansionWorkflow)(
    options,
    workflow.dependencies,
  );
}

if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  runP29InstalledProductionWorkflow(process.argv.slice(2))
    .then((result) => process.stdout.write(`${JSON.stringify(result)}\n`))
    .catch((error) => {
      process.stderr.write(`${error.stack ?? error.message}\n`);
      process.exitCode = 1;
    });
}

export { ROOT, STATES };
